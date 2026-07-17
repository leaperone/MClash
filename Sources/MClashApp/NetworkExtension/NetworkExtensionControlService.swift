import MClashNetworkShared

protocol NetworkExtensionControlling: Sendable {
    func enable(
        _ configuration: NetworkExtensionRuntimeConfiguration,
        progress reportProgress: @escaping @Sendable (NetworkExtensionEnableProgress) -> Void
    ) async throws -> NetworkExtensionEnableOutcome
    func disable() async throws
    func uninstall() async throws -> NetworkExtensionUninstallOutcome
    func currentState() async -> NetworkExtensionControlState
    func appRoutingActivity(after cursor: UInt64, limit: Int) async throws
        -> AppRoutingActivityBatch
    func clearAppRoutingActivity() async throws
}

extension NetworkExtensionControlling {
    func enable(
        _ configuration: NetworkExtensionRuntimeConfiguration
    ) async throws -> NetworkExtensionEnableOutcome {
        try await enable(configuration, progress: { _ in })
    }
}

actor NetworkExtensionControlService: NetworkExtensionControlling {
    private let systemExtension: any SystemExtensionControlling
    private let transparentProxy: any TransparentProxyManaging
    private let dnsProxy: any DNSProxyManaging

    private(set) var state: NetworkExtensionControlState = .inactive

    init(
        systemExtension: any SystemExtensionControlling,
        transparentProxy: any TransparentProxyManaging,
        dnsProxy: any DNSProxyManaging
    ) {
        self.systemExtension = systemExtension
        self.transparentProxy = transparentProxy
        self.dnsProxy = dnsProxy
    }

    static func live() -> NetworkExtensionControlService {
        NetworkExtensionControlService(
            systemExtension: AppleSystemExtensionController(),
            transparentProxy: AppleTransparentProxyManager(),
            dnsProxy: AppleDNSProxyManager()
        )
    }

    func enable(
        _ configuration: NetworkExtensionRuntimeConfiguration,
        progress reportProgress: @escaping @Sendable (NetworkExtensionEnableProgress) -> Void
    ) async throws -> NetworkExtensionEnableOutcome {
        if state.phase == .running,
           state.revision == configuration.revision,
           state.dnsRequested == configuration.dnsEnabled
        {
            return .running
        }

        // A revision change is a controlled restart. Reusing an already-open
        // provider while replacing preferences creates a window where the host
        // and provider disagree about the active revision.
        if state.phase == .running || state.phase == .failed {
            try await disable()
        }

        try transition(.beginEnable(
            revision: configuration.revision,
            dnsEnabled: configuration.dnsEnabled
        ))

        var operation = NetworkExtensionControlOperation.activateSystemExtension
        do {
            let result = try await systemExtension.activate { [weak self] systemProgress in
                guard systemProgress == .awaitingUserApproval else { return }
                reportProgress(.awaitingSystemExtensionApproval)
                Task { await self?.recordUserApprovalRequirement() }
            }
            if result == .requiresReboot {
                try transition(.rebootRequired)
                return .requiresReboot
            }
            try transition(.systemExtensionActivated)

            operation = .configureTransparentProxy
            try await transparentProxy.configure(configuration)
            try await transparentProxy.reload()
            try transition(.transparentProxyConfigured)

            operation = .startTransparentProxy
            try await transparentProxy.start()
            let providerStatus = try await transparentProxy.providerStatus()
            guard providerStatus.running,
                  providerStatus.captureEnabled == configuration.captureEnabled,
                  providerStatus.revision == configuration.revision
            else {
                throw NetworkExtensionControlFailure(
                    operation: .startTransparentProxy,
                    message: "The transparent proxy connected but did not activate revision \(configuration.revision)."
                )
            }
            try transition(.transparentProxyStarted)

            if configuration.dnsEnabled {
                operation = .configureDNSProxy
                try await dnsProxy.configureAndEnable(configuration)
                try await dnsProxy.reload()
                try transition(.dnsProxyConfigured)
            }

            return .running
        } catch {
            // Roll back in reverse data-plane order. DNS is always disabled
            // first, before the transparent provider and its local backend can
            // stop, so no resolver traffic is left pointing at a dead relay.
            try? await dnsProxy.disable()
            try? await transparentProxy.stop()
            let failure = NetworkExtensionControlFailure(
                operation: operation,
                underlying: error
            )
            try? transition(.failed(failure))
            throw failure
        }
    }

    func disable() async throws {
        guard state.phase != .inactive && state.phase != .uninstalled else {
            return
        }
        try transition(.beginDisable)

        do {
            try await dnsProxy.disable()
            try transition(.dnsProxyDisabled)
        } catch {
            let failure = NetworkExtensionControlFailure(
                operation: .disableDNSProxy,
                underlying: error
            )
            try? transition(.failed(failure))
            throw failure
        }

        do {
            try await transparentProxy.stop()
            try transition(.transparentProxyStopped)
        } catch {
            let failure = NetworkExtensionControlFailure(
                operation: .stopTransparentProxy,
                underlying: error
            )
            try? transition(.failed(failure))
            throw failure
        }
    }

    func uninstall() async throws -> NetworkExtensionUninstallOutcome {
        if state.phase == .uninstalled {
            return .uninstalled
        }
        if state.phase != .inactive {
            try await disable()
        }

        try transition(.beginDeactivation)
        do {
            let result = try await systemExtension.deactivate { [weak self] progress in
                guard progress == .awaitingUserApproval else { return }
                Task { await self?.recordUserApprovalRequirement() }
            }
            if result == .requiresReboot {
                try transition(.rebootRequired)
                return .requiresReboot
            }
            try transition(.systemExtensionDeactivated)
            return .uninstalled
        } catch {
            let failure = NetworkExtensionControlFailure(
                operation: .deactivateSystemExtension,
                underlying: error
            )
            try? transition(.failed(failure))
            throw failure
        }
    }

    func currentState() -> NetworkExtensionControlState {
        state
    }

    func appRoutingActivity(
        after cursor: UInt64,
        limit: Int
    ) async throws -> AppRoutingActivityBatch {
        try await transparentProxy.appRoutingActivity(after: cursor, limit: limit)
    }

    func clearAppRoutingActivity() async throws {
        try await transparentProxy.clearAppRoutingActivity()
    }

    private func transition(_ event: NetworkExtensionControlEvent) throws {
        do {
            state = try NetworkExtensionControlReducer.reduce(state, event)
        } catch {
            throw NetworkExtensionControlFailure(
                operation: .stateTransition,
                underlying: error
            )
        }
    }

    private func recordUserApprovalRequirement() {
        try? transition(.systemExtensionNeedsApproval)
    }
}
