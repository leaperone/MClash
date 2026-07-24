import MClashNetworkShared
import OSLog

private let networkExtensionControlLogger = Logger(
    subsystem: "one.leaper.mclash",
    category: "NetworkExtensionControl"
)

protocol NetworkExtensionControlling: Sendable {
    func enable(
        _ configuration: NetworkExtensionRuntimeConfiguration,
        progress reportProgress: @escaping @Sendable (NetworkExtensionEnableProgress) -> Void
    ) async throws -> NetworkExtensionEnableOutcome
    func updateRuntimeConfiguration(
        _ configuration: NetworkExtensionRuntimeConfiguration
    ) async throws -> NetworkExtensionEnableOutcome
    func disable() async throws
    func uninstall() async throws -> NetworkExtensionUninstallOutcome
    func currentState() async -> NetworkExtensionControlState
    func providerRuntimeStatus() async throws -> TransparentProxyProviderStatus
    func dnsProviderRuntimeStatus() async throws -> DNSProxyRuntimeStatus?
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

    func dnsProviderRuntimeStatus() async throws -> DNSProxyRuntimeStatus? { nil }

    func updateRuntimeConfiguration(
        _ configuration: NetworkExtensionRuntimeConfiguration
    ) async throws -> NetworkExtensionEnableOutcome {
        try await enable(configuration)
    }

}

actor NetworkExtensionControlService: NetworkExtensionControlling {
    private let systemExtension: any SystemExtensionControlling
    private let transparentProxy: any TransparentProxyManaging
    private let dnsProxy: any DNSProxyManaging
    private var activeConfiguration: NetworkExtensionRuntimeConfiguration?
    /// Tracks the independently verified DNS Provider activation. DNS has no
    /// provider-message update channel, so any rule update while DNS Routing
    /// is enabled uses a controlled full data-plane restart.
    private var activeDNSConfiguration: NetworkExtensionRuntimeConfiguration?
    /// Every committed activation owns a generation. Cleanup invalidates it
    /// before touching either Provider, so a System Extension approval that
    /// completes later cannot resume an obsolete activation transaction.
    private var operationGeneration: UInt64 = 0
    /// Actor reentrancy alone does not serialize external preference writes.
    /// This gate starts only after System Extension approval, allowing disable
    /// to invalidate a pending approval immediately while ensuring cleanup is
    /// the final writer once any Provider mutation has already begun.
    private var providerMutationInProgress = false
    private var providerMutationWaiters: [CheckedContinuation<Void, Never>] = []

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
        let transparentProxy = AppleTransparentProxyManager()
        return NetworkExtensionControlService(
            systemExtension: AppleSystemExtensionController(),
            transparentProxy: transparentProxy,
            dnsProxy: AppleDNSProxyManager(runtimeChannel: transparentProxy)
        )
    }

    func enable(
        _ configuration: NetworkExtensionRuntimeConfiguration,
        progress reportProgress: @escaping @Sendable (NetworkExtensionEnableProgress) -> Void
    ) async throws -> NetworkExtensionEnableOutcome {
        networkExtensionControlLogger.notice(
            "Enable requested revision=\(configuration.revision, privacy: .public) dns=\(configuration.dnsEnabled, privacy: .public) cachedPhase=\(self.state.phase.rawValue, privacy: .public)"
        )
        if state.phase == .running,
           state.revision == configuration.revision,
           state.dnsRequested == configuration.dnsEnabled
        {
            // The host process may outlive or lose contact with the provider.
            // Never treat the actor's cached state as proof that capture is
            // still active.
            if let providerStatus = try? await providerRuntimeStatus(),
               providerStatus.matches(configuration),
               await dnsRuntimeMatches(configuration)
            {
                activeConfiguration = configuration
                networkExtensionControlLogger.notice(
                    "Existing data plane verified revision=\(configuration.revision, privacy: .public)"
                )
                return .running
            }
        }

        // The host actor starts without in-memory state after login or a crash,
        // while macOS may still own provider preferences from the prior
        // process. Quiesce both data planes before publishing new listener
        // credentials so an old provider can never relay to a dead core.
        if state.phase == .inactive {
            try await disable()
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
        operationGeneration &+= 1
        let generation = operationGeneration
        var ownsProviderMutation = false
        defer {
            if ownsProviderMutation {
                endProviderMutation()
            }
        }

        var operation = NetworkExtensionControlOperation.activateSystemExtension
        do {
            let result = try await systemExtension.activate { [weak self] systemProgress in
                guard systemProgress == .awaitingUserApproval else { return }
                reportProgress(.awaitingSystemExtensionApproval)
                Task {
                    await self?.recordUserApprovalRequirement(
                        generation: generation
                    )
                }
            }
            try ensureOperationCurrent(generation)
            if result == .requiresReboot {
                activeConfiguration = nil
                try transition(.rebootRequired)
                networkExtensionControlLogger.notice(
                    "System Extension activation requires reboot revision=\(configuration.revision, privacy: .public)"
                )
                return .requiresReboot
            }
            try transition(.systemExtensionActivated)
            networkExtensionControlLogger.debug(
                "System Extension active revision=\(configuration.revision, privacy: .public)"
            )
            await beginProviderMutation()
            ownsProviderMutation = true
            try ensureOperationCurrent(generation)

            operation = .configureTransparentProxy
            try await transparentProxy.configure(configuration)
            try ensureOperationCurrent(generation)
            try await transparentProxy.reload()
            try ensureOperationCurrent(generation)
            try transition(.transparentProxyConfigured)
            networkExtensionControlLogger.debug(
                "Transparent Proxy preferences verified revision=\(configuration.revision, privacy: .public)"
            )

            operation = .startTransparentProxy
            try await transparentProxy.start()
            try ensureOperationCurrent(generation)
            let providerStatus = try await transparentProxy.providerStatus()
            try ensureOperationCurrent(generation)
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
            networkExtensionControlLogger.notice(
                "Transparent Proxy Provider verified revision=\(providerStatus.revision, privacy: .public) running=\(providerStatus.running, privacy: .public) capture=\(providerStatus.captureEnabled, privacy: .public)"
            )

            if configuration.dnsEnabled {
                operation = .configureDNSProxy
                try await dnsProxy.configureAndEnable(configuration)
                try ensureOperationCurrent(generation)
                try await dnsProxy.reload()
                try ensureOperationCurrent(generation)
                try transition(.dnsProxyConfigured)
                activeDNSConfiguration = configuration
                networkExtensionControlLogger.notice(
                    "DNS Proxy preferences and Provider heartbeat verified revision=\(configuration.revision, privacy: .public)"
                )
            } else {
                // Advanced DNS opt-out is explicit runtime state, not merely
                // an instruction to skip setup. Clear any owned configuration
                // left enabled by an older version or interrupted activation.
                operation = .disableDNSProxy
                try await dnsProxy.disable()
                try ensureOperationCurrent(generation)
                activeDNSConfiguration = nil
            }

            try ensureOperationCurrent(generation)
            activeConfiguration = configuration
            networkExtensionControlLogger.notice(
                "Enable committed revision=\(configuration.revision, privacy: .public) dns=\(configuration.dnsEnabled, privacy: .public)"
            )
            return .running
        } catch {
            guard generation == operationGeneration else {
                networkExtensionControlLogger.notice(
                    "Obsolete enable transaction discarded revision=\(configuration.revision, privacy: .public)"
                )
                throw CancellationError()
            }
            if !ownsProviderMutation {
                await beginProviderMutation()
                ownsProviderMutation = true
                try ensureOperationCurrent(generation)
            }
            activeConfiguration = nil
            activeDNSConfiguration = nil
            // Roll back in reverse data-plane order. DNS is always disabled
            // first, before the transparent provider and its local backend can
            // stop, so no resolver traffic is left pointing at a dead relay.
            var rollbackFailures: [String] = []
            do {
                try await dnsProxy.disable()
            } catch {
                rollbackFailures.append(
                    "DNS rollback failed: \(error.localizedDescription)"
                )
            }
            do {
                try await transparentProxy.stop()
            } catch {
                rollbackFailures.append(
                    "Transparent proxy rollback failed: \(error.localizedDescription)"
                )
            }
            let primary = NetworkExtensionControlFailure(
                operation: operation,
                underlying: error
            )
            let failure = rollbackFailures.isEmpty
                ? primary
                : NetworkExtensionControlFailure(
                    operation: operation,
                    message: ([primary.message] + rollbackFailures).joined(separator: " · ")
                )
            try? transition(.failed(failure))
            networkExtensionControlLogger.error(
                "Enable rolled back revision=\(configuration.revision, privacy: .public) operation=\(operation.rawValue, privacy: .public) error=\(failure.localizedDescription, privacy: .public) rollbackFailures=\(rollbackFailures.count, privacy: .public)"
            )
            throw failure
        }
    }

    /// Applies rule-only changes without stopping the transparent provider
    /// when DNS Routing is disabled. With DNS enabled, the DNS Provider needs
    /// the same snapshot and route catalog as transparent capture, and because
    /// it has no provider-message update channel this method falls back to the
    /// controlled full enable transaction.
    func updateRuntimeConfiguration(
        _ configuration: NetworkExtensionRuntimeConfiguration
    ) async throws -> NetworkExtensionEnableOutcome {
        guard state.phase == .running,
              let previous = activeConfiguration,
              previous.captureEnabled,
              configuration.captureEnabled,
              configuration.revision > previous.revision,
              !configuration.dnsEnabled,
              configuration.dnsEnabled == previous.dnsEnabled,
              configuration.mihomoListener == previous.mihomoListener
        else {
            return try await enable(configuration)
        }

        networkExtensionControlLogger.notice(
            "Live update requested previousRevision=\(previous.revision, privacy: .public) revision=\(configuration.revision, privacy: .public)"
        )
        let liveConfiguration = configuration
        let generation = operationGeneration
        await beginProviderMutation()
        defer { endProviderMutation() }
        try ensureOperationCurrent(generation)
        do {
            // Persist first. Apple exposes protocolConfiguration changes to the
            // current provider session; the explicit provider message below is
            // still the atomic decision-state commit used by MClash.
            try await transparentProxy.configure(liveConfiguration)
            try ensureOperationCurrent(generation)
            try await transparentProxy.reload()
            try ensureOperationCurrent(generation)
            let status = try await transparentProxy.updateProviderConfiguration(
                liveConfiguration
            )
            try ensureOperationCurrent(generation)
            guard status.matches(liveConfiguration) else {
                throw NetworkExtensionControlFailure(
                    operation: .configureTransparentProxy,
                    message: "The transparent proxy did not verify live revision \(liveConfiguration.revision)."
                )
            }

            activeConfiguration = liveConfiguration
            state.revision = liveConfiguration.revision
            state.failure = nil
            networkExtensionControlLogger.notice(
                "Live update committed revision=\(liveConfiguration.revision, privacy: .public); DNS Routing is disabled"
            )
            return .running
        } catch {
            guard generation == operationGeneration else {
                throw CancellationError()
            }
            let failure = error as? NetworkExtensionControlFailure
                ?? NetworkExtensionControlFailure(
                    operation: .configureTransparentProxy,
                    underlying: error
                )
            try? transition(.failed(failure))
            networkExtensionControlLogger.error(
                "Live update failed revision=\(configuration.revision, privacy: .public) error=\(failure.localizedDescription, privacy: .public)"
            )
            throw failure
        }
    }

    func disable() async throws {
        operationGeneration &+= 1
        let generation = operationGeneration
        networkExtensionControlLogger.notice(
            "Disable requested cachedPhase=\(self.state.phase.rawValue, privacy: .public) revision=\(String(describing: self.state.revision), privacy: .public)"
        )
        let hasTrackedOperation = state.phase != .inactive && state.phase != .uninstalled
        if hasTrackedOperation {
            try transition(.beginDisable)
        }
        await beginProviderMutation()
        defer { endProviderMutation() }
        guard generation == operationGeneration else { return }

        do {
            try await dnsProxy.disable()
            guard generation == operationGeneration else { return }
            if hasTrackedOperation {
                try transition(.dnsProxyDisabled)
            }
        } catch {
            let failure = NetworkExtensionControlFailure(
                operation: .disableDNSProxy,
                underlying: error
            )
            try? transition(.failed(failure))
            networkExtensionControlLogger.error(
                "Disable failed operation=\(failure.operation.rawValue, privacy: .public) error=\(failure.localizedDescription, privacy: .public)"
            )
            throw failure
        }

        do {
            try await transparentProxy.stop()
            guard generation == operationGeneration else { return }
            if hasTrackedOperation {
                try transition(.transparentProxyStopped)
            }
        } catch {
            let failure = NetworkExtensionControlFailure(
                operation: .stopTransparentProxy,
                underlying: error
            )
            try? transition(.failed(failure))
            networkExtensionControlLogger.error(
                "Disable failed operation=\(failure.operation.rawValue, privacy: .public) error=\(failure.localizedDescription, privacy: .public)"
            )
            throw failure
        }
        activeConfiguration = nil
        activeDNSConfiguration = nil
        networkExtensionControlLogger.notice("Disable committed; DNS and Transparent Proxy are off")
    }

    func uninstall() async throws -> NetworkExtensionUninstallOutcome {
        if state.phase == .uninstalled {
            return .uninstalled
        }
        if state.phase != .inactive {
            try await disable()
        }

        try transition(.beginDeactivation)
        operationGeneration &+= 1
        let generation = operationGeneration
        do {
            let result = try await systemExtension.deactivate { [weak self] progress in
                guard progress == .awaitingUserApproval else { return }
                Task {
                    await self?.recordUserApprovalRequirement(
                        generation: generation
                    )
                }
            }
            try ensureOperationCurrent(generation)
            if result == .requiresReboot {
                try transition(.rebootRequired)
                return .requiresReboot
            }
            try transition(.systemExtensionDeactivated)
            return .uninstalled
        } catch {
            guard generation == operationGeneration else {
                throw CancellationError()
            }
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

    func providerRuntimeStatus() async throws -> TransparentProxyProviderStatus {
        try await transparentProxy.providerStatus()
    }

    func dnsProviderRuntimeStatus() async throws -> DNSProxyRuntimeStatus? {
        guard let activeDNSConfiguration else { return nil }
        return try await dnsProxy.runtimeStatus(for: activeDNSConfiguration)
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

    private func recordUserApprovalRequirement(generation: UInt64) {
        guard generation == operationGeneration else { return }
        try? transition(.systemExtensionNeedsApproval)
    }

    private func ensureOperationCurrent(_ generation: UInt64) throws {
        guard generation == operationGeneration else {
            throw CancellationError()
        }
        try Task.checkCancellation()
    }

    private func beginProviderMutation() async {
        guard providerMutationInProgress else {
            providerMutationInProgress = true
            return
        }
        await withCheckedContinuation { continuation in
            providerMutationWaiters.append(continuation)
        }
    }

    private func endProviderMutation() {
        guard !providerMutationWaiters.isEmpty else {
            providerMutationInProgress = false
            return
        }
        providerMutationWaiters.removeFirst().resume()
    }

    private func dnsRuntimeMatches(
        _ configuration: NetworkExtensionRuntimeConfiguration
    ) async -> Bool {
        guard configuration.dnsEnabled else { return true }
        guard let activeDNSConfiguration,
              let status = try? await dnsProxy.runtimeStatus(
                  for: activeDNSConfiguration
              ) else {
            return false
        }
        return status.isOperational
    }
}

private extension TransparentProxyProviderStatus {
    func matches(_ configuration: NetworkExtensionRuntimeConfiguration) -> Bool {
        running
            && captureEnabled == configuration.captureEnabled
            && revision == configuration.revision
    }
}
