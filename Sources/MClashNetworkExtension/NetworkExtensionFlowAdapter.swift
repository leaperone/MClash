import Foundation
import MClashNetworkShared
import Network
import NetworkExtension

final class NetworkExtensionFlowDecisionCoordinator: @unchecked Sendable {
    private struct State: Sendable {
        var revision: UInt64 = 0
        var captureEnabled = false
        var configuration: CaptureConfigurationLoadResult = .failOpen(.missingEncodedSnapshot)
        var mihomoSOCKSConfiguration: ProviderSOCKSConfiguration?
    }

    private let lock = NSLock()
    private let identityResolver = ProcessIdentityResolver()
    private let trustedComponentPolicy = TrustedMClashComponentPolicy()
    private let contextBuilder = FlowContextBuilder()
    private let decisionAdapter = FlowTrafficDecisionAdapter()
    private var state = State()

    func load(configuration: [String: Any]?) {
        let captureEnabled = Self.bool(
            configuration?[ProviderConfigurationKey.captureEnabled]
        ) ?? false
        let encodedSnapshot = configuration?[
            ProviderConfigurationKey.captureConfigurationSnapshot
        ] as? Data
        let loadResult = CaptureConfigurationSnapshotLoader().load(encodedSnapshot)

        lock.lock()
        state.revision = Self.uint64(configuration?[ProviderConfigurationKey.revision]) ?? 0
        state.captureEnabled = captureEnabled
        state.configuration = loadResult
        state.mihomoSOCKSConfiguration = ProviderSOCKSConfiguration(
            providerConfiguration: configuration
        )
        lock.unlock()
    }

    func quiesce() {
        lock.lock()
        state.captureEnabled = false
        lock.unlock()
    }

    func validates(configuration: [String: Any]) -> Bool {
        let captureEnabled = Self.bool(
            configuration[ProviderConfigurationKey.captureEnabled]
        ) ?? false
        guard captureEnabled else { return true }
        let snapshot = CaptureConfigurationSnapshotLoader().load(
            configuration[ProviderConfigurationKey.captureConfigurationSnapshot] as? Data
        )
        guard case .loaded = snapshot else { return false }
        return ProviderSOCKSConfiguration(providerConfiguration: configuration) != nil
    }

    func planTCPFlow(_ flow: NEAppProxyTCPFlow) -> TCPFlowInterceptionPlan {
        let endpoint: FlowRemoteEndpoint
        if #available(macOS 15.0, *) {
            guard let converted = Self.endpoint(flow.remoteFlowEndpoint) else {
                return TCPFlowInterceptionPlan(
                    decision: failOpen(.unsupportedRemoteEndpoint),
                    destination: nil,
                    proxy: nil,
                    unavailableFallback: .direct,
                    activity: fallbackActivity(
                        flow: flow,
                        endpoint: nil,
                        transportProtocol: .tcp,
                        failure: .unsupportedRemoteEndpoint
                    )
                )
            }
            endpoint = converted
        } else {
            guard let converted = Self.legacyEndpoint(flow.__remoteEndpoint) else {
                return TCPFlowInterceptionPlan(
                    decision: failOpen(.unsupportedRemoteEndpoint),
                    destination: nil,
                    proxy: nil,
                    unavailableFallback: .direct,
                    activity: fallbackActivity(
                        flow: flow,
                        endpoint: nil,
                        transportProtocol: .tcp,
                        failure: .unsupportedRemoteEndpoint
                    )
                )
            }
            endpoint = converted
        }
        let currentState = snapshotState()
        let outcome = decide(
            flow: flow,
            endpoint: endpoint,
            transportProtocol: .tcp,
            state: currentState
        )
        let destination = try? ProviderSOCKSConfiguration.destination(for: endpoint)
        return TCPFlowInterceptionPlan(
            decision: outcome.decision,
            destination: destination,
            proxy: currentState.mihomoSOCKSConfiguration,
            unavailableFallback: unavailableFallbackRequested(
                by: outcome.decision,
                configuration: currentState.configuration
            ),
            activity: outcome.activity
        )
    }

    func decideTCPFlow(_ flow: NEAppProxyTCPFlow) -> FlowTrafficDecision {
        planTCPFlow(flow).decision
    }

    @available(macOS 15.0, *)
    func planUDPFlow(
        _ flow: NEAppProxyUDPFlow,
        initialRemoteEndpoint: Network.NWEndpoint
    ) -> UDPFlowInterceptionPlan {
        guard let endpoint = Self.endpoint(initialRemoteEndpoint) else {
            return UDPFlowInterceptionPlan(
                decision: failOpen(.unsupportedRemoteEndpoint),
                initialDestination: nil,
                proxy: nil,
                activity: fallbackActivity(
                    flow: flow,
                    endpoint: nil,
                    transportProtocol: .udp,
                    failure: .unsupportedRemoteEndpoint
                )
            )
        }
        return planUDPFlow(
            flow: flow,
            endpoint: endpoint,
            state: snapshotState()
        )
    }

    @available(macOS 15.0, *)
    func decideUDPFlow(
        _ flow: NEAppProxyUDPFlow,
        initialRemoteEndpoint: Network.NWEndpoint
    ) -> FlowTrafficDecision {
        planUDPFlow(flow, initialRemoteEndpoint: initialRemoteEndpoint).decision
    }

    @available(macOS, introduced: 14.0, obsoleted: 15.0)
    func planLegacyUDPFlow(
        _ flow: NEAppProxyUDPFlow,
        initialRemoteEndpoint: NetworkExtension.__NWEndpoint
    ) -> UDPFlowInterceptionPlan {
        guard let endpoint = Self.legacyEndpoint(initialRemoteEndpoint) else {
            return UDPFlowInterceptionPlan(
                decision: failOpen(.unsupportedRemoteEndpoint),
                initialDestination: nil,
                proxy: nil,
                activity: fallbackActivity(
                    flow: flow,
                    endpoint: nil,
                    transportProtocol: .udp,
                    failure: .unsupportedRemoteEndpoint
                )
            )
        }
        return planUDPFlow(
            flow: flow,
            endpoint: endpoint,
            state: snapshotState()
        )
    }

    @available(macOS, introduced: 14.0, obsoleted: 15.0)
    func decideLegacyUDPFlow(
        _ flow: NEAppProxyUDPFlow,
        initialRemoteEndpoint: NetworkExtension.__NWEndpoint
    ) -> FlowTrafficDecision {
        planLegacyUDPFlow(flow, initialRemoteEndpoint: initialRemoteEndpoint).decision
    }

    func failOpen(_ failure: FlowContextConversionFailure) -> FlowTrafficDecision {
        let currentState = snapshotState()
        return decisionAdapter.decide(
            configuration: currentState.configuration,
            context: .failOpen(failure),
            captureEnabled: currentState.captureEnabled,
            mihomoAvailable: false
        )
    }

    private func decide(
        flow: NEAppProxyFlow,
        endpoint: FlowRemoteEndpoint,
        transportProtocol: TransportProtocol,
        state currentState: State
    ) -> FlowDecisionOutcome {
        let metadata = flow.metaData
        let applicationMetadata = FlowApplicationMetadata(
            sourceAppAuditToken: metadata.sourceAppAuditToken,
            sourceAppUniqueIdentifier: metadata.sourceAppUniqueIdentifier,
            sourceAppSigningIdentifier: metadata.sourceAppSigningIdentifier
        )
        let identityResolution: ProcessIdentityResolution
        if let auditToken = applicationMetadata.sourceAppAuditToken {
            identityResolution = identityResolver.resolve(sourceAppAuditToken: auditToken)
        } else {
            identityResolution = .unavailable(.invalidAuditTokenLength(expected: 32, actual: 0))
        }
        let context = contextBuilder.resolve(
            endpoint: endpoint,
            remoteHostname: flow.remoteHostname,
            metadata: applicationMetadata,
            identityResolution: identityResolution,
            transportProtocol: transportProtocol,
            isTrustedMClashComponent: trustedComponentPolicy.contains(identityResolution)
        )
        let decision = decisionAdapter.decide(
            configuration: currentState.configuration,
            context: context,
            captureEnabled: currentState.captureEnabled,
            mihomoAvailable: currentState.mihomoSOCKSConfiguration != nil
        )
        return FlowDecisionOutcome(
            decision: decision,
            activity: makeActivity(
                flow: flow,
                endpoint: endpoint,
                transportProtocol: transportProtocol,
                context: context,
                identityResolution: identityResolution,
                decision: decision,
                state: currentState
            )
        )
    }

    private func planUDPFlow(
        flow: NEAppProxyUDPFlow,
        endpoint: FlowRemoteEndpoint,
        state currentState: State
    ) -> UDPFlowInterceptionPlan {
        let outcome = decide(
            flow: flow,
            endpoint: endpoint,
            transportProtocol: .udp,
            state: currentState
        )
        let destination = try? currentState.mihomoSOCKSConfiguration?.destination(
            for: endpoint
        )
        return UDPFlowInterceptionPlan(
            decision: outcome.decision,
            initialDestination: destination,
            proxy: currentState.mihomoSOCKSConfiguration,
            activity: outcome.activity
        )
    }

    private func makeActivity(
        flow: NEAppProxyFlow,
        endpoint: FlowRemoteEndpoint,
        transportProtocol: TransportProtocol,
        context: FlowContextResolution,
        identityResolution: ProcessIdentityResolution,
        decision: FlowTrafficDecision,
        state: State
    ) -> AppRoutingActivity {
        let resolvedContext = context.context
        let identity = identityResolution.identity
        let signing: SignedCodeIdentity?
        if case let .signed(value) = identity?.codeSigning {
            signing = value
        } else {
            signing = nil
        }
        let source = resolvedContext?.source
        let resolvedDestination = resolvedContext?.destination
        let endpointHost = endpoint.host.trimmingCharacters(in: .whitespacesAndNewlines)
        let endpointAddress = try? IPAddress(endpointHost.trimmingCharacters(in: CharacterSet(charactersIn: "[]")))
        let configuredAction = actionRequested(
            by: decision,
            configuration: state.configuration
        )
        let terminal = Self.isTerminalWithoutRelay(
            decision,
            transportProtocol: transportProtocol
        )

        return AppRoutingActivity(
            configurationRevision: state.revision,
            startedAt: Date(),
            endedAt: terminal ? Date() : nil,
            source: AppRoutingActivitySource(
                processIdentifier: source?.processIdentifier ?? identity?.processIdentifier ?? 0,
                processStartTime: source?.processStartTime ?? identity?.processStartTime,
                userIdentifier: source?.userID ?? identity?.effectiveUserID ?? 0,
                executablePath: source?.executablePath ?? identity?.executablePath,
                bundleIdentifier: source?.bundleIdentifier ?? signing?.securedBundleIdentifier,
                signingIdentifier: source?.signingIdentifier ?? signing?.signingIdentifier,
                teamIdentifier: source?.teamIdentifier ?? signing?.teamIdentifier
            ),
            destination: AppRoutingActivityDestination(
                hostname: resolvedDestination?.hostname ?? flow.remoteHostname,
                ipAddress: resolvedDestination?.ipAddress?.presentation ?? endpointAddress?.presentation,
                port: resolvedDestination?.port ?? UInt16(endpoint.port) ?? 0
            ),
            transportProtocol: transportProtocol,
            decision: decision,
            configuredAction: configuredAction,
            effectiveAction: decision.disposition,
            relayState: terminal ? .notApplicable : .pending
        )
    }

    private func fallbackActivity(
        flow: NEAppProxyFlow,
        endpoint: FlowRemoteEndpoint?,
        transportProtocol: TransportProtocol,
        failure: FlowContextConversionFailure
    ) -> AppRoutingActivity {
        let currentState = snapshotState()
        let decision = failOpen(failure)
        let metadata = flow.metaData
        return AppRoutingActivity(
            configurationRevision: currentState.revision,
            startedAt: Date(),
            endedAt: Date(),
            source: AppRoutingActivitySource(
                processIdentifier: 0,
                userIdentifier: 0,
                signingIdentifier: metadata.sourceAppSigningIdentifier
            ),
            destination: AppRoutingActivityDestination(
                hostname: flow.remoteHostname,
                ipAddress: endpoint?.host,
                port: endpoint.flatMap { UInt16($0.port) } ?? 0
            ),
            transportProtocol: transportProtocol,
            decision: decision,
            configuredAction: .direct,
            effectiveAction: .failOpen,
            relayState: .notApplicable,
            relayError: failure.description
        )
    }

    private func actionRequested(
        by decision: FlowTrafficDecision,
        configuration: CaptureConfigurationLoadResult
    ) -> CaptureAction {
        let cause: RuleDecisionCause?
        switch decision.reason {
        case let .rule(value):
            cause = value
        case let .mihomoUnavailable(rule, _):
            cause = rule
        case .captureDisabled, .configurationUnavailable, .contextUnavailable:
            cause = nil
        }
        if case let .matchedRule(identifier) = cause,
           case let .loaded(snapshot) = configuration,
           let rule = snapshot.rules.first(where: { $0.id == identifier }) {
            return rule.action
        }
        return switch decision.disposition {
        case .reject: .reject
        case let .mihomo(route): .mihomo(route)
        case .direct, .failOpen: .direct
        }
    }

    private func unavailableFallbackRequested(
        by decision: FlowTrafficDecision,
        configuration: CaptureConfigurationLoadResult
    ) -> UnavailableFallback {
        let cause: RuleDecisionCause?
        switch decision.reason {
        case let .rule(value):
            cause = value
        case let .mihomoUnavailable(rule, fallback):
            if case .matchedRule = rule {
                return fallback
            }
            cause = rule
        case .captureDisabled, .configurationUnavailable, .contextUnavailable:
            cause = nil
        }
        if case let .matchedRule(identifier) = cause,
           case let .loaded(snapshot) = configuration,
           let rule = snapshot.rules.first(where: { $0.id == identifier }) {
            return rule.unavailableFallback
        }
        return .direct
    }

    private static func isTerminalWithoutRelay(
        _ decision: FlowTrafficDecision,
        transportProtocol: TransportProtocol
    ) -> Bool {
        switch decision.disposition {
        case .direct:
            guard transportProtocol == .tcp else { return true }
            if case let .rule(cause) = decision.reason,
               case .builtInBypass = cause {
                return true
            }
            return false
        case .reject, .failOpen:
            return true
        case .mihomo:
            return false
        }
    }

    private func snapshotState() -> State {
        lock.lock()
        defer { lock.unlock() }
        return state
    }

    @available(macOS 15.0, *)
    private static func endpoint(_ endpoint: Network.NWEndpoint) -> FlowRemoteEndpoint? {
        guard case let .hostPort(host, port) = endpoint else { return nil }
        return FlowRemoteEndpoint(host: host.debugDescription, port: port.rawValue)
    }

    @available(macOS, introduced: 14.0, obsoleted: 15.0)
    private static func legacyEndpoint(
        _ endpoint: NetworkExtension.__NWEndpoint
    ) -> FlowRemoteEndpoint? {
        // Swift 6 hides the deprecated NWHostEndpoint wrapper. KVC keeps the
        // macOS 14 compatibility path isolated without importing deprecated
        // members into the strict-concurrency build.
        let object = endpoint as NSObject
        guard object.isKind(of: NetworkExtension.__NWHostEndpoint.self),
              let host = object.value(forKey: "hostname") as? String,
              let port = object.value(forKey: "port") as? String
        else {
            return nil
        }
        return FlowRemoteEndpoint(host: host, port: port)
    }

    private static func bool(_ value: Any?) -> Bool? {
        switch value {
        case let value as Bool: value
        case let value as NSNumber: value.boolValue
        case let value as String:
            switch value.lowercased() {
            case "true", "yes", "1": true
            case "false", "no", "0": false
            default: nil
            }
        default: nil
        }
    }

    private static func uint64(_ value: Any?) -> UInt64? {
        switch value {
        case let value as UInt64: value
        case let value as Int where value >= 0: UInt64(value)
        case let value as NSNumber where value.int64Value >= 0: value.uint64Value
        case let value as String: UInt64(value)
        default: nil
        }
    }
}

private struct FlowDecisionOutcome: Sendable {
    let decision: FlowTrafficDecision
    let activity: AppRoutingActivity
}

struct TCPFlowInterceptionPlan: Sendable {
    let decision: FlowTrafficDecision
    let destination: SOCKS5Endpoint?
    let proxy: ProviderSOCKSConfiguration?
    let unavailableFallback: UnavailableFallback
    let activity: AppRoutingActivity
}

struct UDPFlowInterceptionPlan: Sendable {
    let decision: FlowTrafficDecision
    let initialDestination: SOCKS5Endpoint?
    let proxy: ProviderSOCKSConfiguration?
    let activity: AppRoutingActivity
}
