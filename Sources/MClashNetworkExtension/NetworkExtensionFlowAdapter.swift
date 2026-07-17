import Foundation
import MClashNetworkShared
import Network
import NetworkExtension

final class NetworkExtensionFlowDecisionCoordinator: @unchecked Sendable {
    private struct State: Sendable {
        var captureEnabled = false
        var configuration: CaptureConfigurationLoadResult = .failOpen(.missingEncodedSnapshot)
        var mihomoSOCKSConfiguration: ProviderSOCKSConfiguration?
    }

    private let lock = NSLock()
    private let identityResolver = ProcessIdentityResolver()
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
                    proxy: nil
                )
            }
            endpoint = converted
        } else {
            guard let converted = Self.legacyEndpoint(flow.__remoteEndpoint) else {
                return TCPFlowInterceptionPlan(
                    decision: failOpen(.unsupportedRemoteEndpoint),
                    destination: nil,
                    proxy: nil
                )
            }
            endpoint = converted
        }
        let currentState = snapshotState()
        let decision = decide(
            flow: flow,
            endpoint: endpoint,
            transportProtocol: .tcp,
            state: currentState
        )
        let destination = try? currentState.mihomoSOCKSConfiguration?.destination(
            for: endpoint
        )
        return TCPFlowInterceptionPlan(
            decision: decision,
            destination: destination,
            proxy: currentState.mihomoSOCKSConfiguration
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
                proxy: nil
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
                proxy: nil
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
    ) -> FlowTrafficDecision {
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
            transportProtocol: transportProtocol
        )
        return decisionAdapter.decide(
            configuration: currentState.configuration,
            context: context,
            captureEnabled: currentState.captureEnabled,
            mihomoAvailable: currentState.mihomoSOCKSConfiguration != nil
        )
    }

    private func planUDPFlow(
        flow: NEAppProxyUDPFlow,
        endpoint: FlowRemoteEndpoint,
        state currentState: State
    ) -> UDPFlowInterceptionPlan {
        let decision = decide(
            flow: flow,
            endpoint: endpoint,
            transportProtocol: .udp,
            state: currentState
        )
        let destination = try? currentState.mihomoSOCKSConfiguration?.destination(
            for: endpoint
        )
        return UDPFlowInterceptionPlan(
            decision: decision,
            initialDestination: destination,
            proxy: currentState.mihomoSOCKSConfiguration
        )
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
}

struct TCPFlowInterceptionPlan: Sendable {
    let decision: FlowTrafficDecision
    let destination: SOCKS5Endpoint?
    let proxy: ProviderSOCKSConfiguration?
}

struct UDPFlowInterceptionPlan: Sendable {
    let decision: FlowTrafficDecision
    let initialDestination: SOCKS5Endpoint?
    let proxy: ProviderSOCKSConfiguration?
}
