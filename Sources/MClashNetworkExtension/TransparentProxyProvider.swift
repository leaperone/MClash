import Foundation
import MClashNetworkShared
@preconcurrency import Network
@preconcurrency import NetworkExtension

/// Transparent application proxy entry point. The framework first sends all
/// outbound TCP/UDP flows (except loopback) to this provider. The local rule
/// engine then returns unselected flows to the original network path and owns
/// only reject or Mihomo-routed flows.
final class TransparentProxyProvider: NETransparentProxyProvider {
    private let runtime = ProviderRuntimeState(providerName: "transparent-proxy")
    private let flowDecisionCoordinator = NetworkExtensionFlowDecisionCoordinator()
    private let tcpRelays = TCPFlowRelayRegistry()
    private let udpRelays = UDPFlowRelayRegistry()
    private let activities = AppRoutingActivityRing(capacity: 2_000)

    override func startProxy(
        options: [String: Any]? = nil,
        completionHandler: @escaping (Error?) -> Void
    ) {
        let providerConfiguration =
            (protocolConfiguration as? NETunnelProviderProtocol)?.providerConfiguration
        let configuration = providerConfiguration ?? options

        guard flowDecisionCoordinator.validates(configuration: configuration ?? [:]) else {
            runtime.start(configuration: nil)
            flowDecisionCoordinator.quiesce()
            completionHandler(Self.invalidBootstrapConfigurationError())
            return
        }

        runtime.start(configuration: configuration)
        flowDecisionCoordinator.load(configuration: configuration)
        let runtime = runtime
        let flowDecisionCoordinator = flowDecisionCoordinator
        let completion = ProxyStartCompletion(completionHandler)
        setTunnelNetworkSettings(Self.transparentProxyNetworkSettings()) { error in
            if error != nil {
                flowDecisionCoordinator.quiesce()
                runtime.stop()
            }
            completion.call(error)
        }
    }

    override func stopProxy(
        with reason: NEProviderStopReason,
        completionHandler: @escaping () -> Void
    ) {
        tcpRelays.cancelAll()
        udpRelays.cancelAll()
        runtime.stop()
        completionHandler()
    }

    override func handleNewFlow(_ flow: NEAppProxyFlow) -> Bool {
        let decision: FlowTrafficDecision
        if let tcpFlow = flow as? NEAppProxyTCPFlow {
            let plan = flowDecisionCoordinator.planTCPFlow(tcpFlow)
            activities.upsert(plan.activity)
            decision = plan.decision
            switch decision.disposition {
            case .direct, .failOpen:
                return false
            case .reject:
                let completion: @Sendable (Error?) -> Void = { error in
                    let rejection = error ?? NSError(
                        domain: "one.leaper.mclash.network-extension",
                        code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "Connection rejected by MClash rule"]
                    )
                    tcpFlow.closeReadWithError(rejection)
                    tcpFlow.closeWriteWithError(rejection)
                }
                AppProxyFlowCompatibility.open(tcpFlow, completion: completion)
                return true
            case let .mihomo(route):
                guard route == .profileRules,
                      let proxy = plan.proxy,
                      let destination = plan.destination
                else {
                    // A generic listener cannot faithfully implement a forced
                    // global/group route. Leave the flow untouched until a
                    // route-specific mihomo listener is configured.
                    recordUnsupportedRoute(plan.activity)
                    return false
                }
                markRelayConnecting(plan.activity.flowIdentifier)
                tcpRelays.start(
                    flow: tcpFlow,
                    proxy: proxy,
                    destination: destination,
                    activityObserver: relayObserver(for: plan.activity.flowIdentifier)
                )
                return true
            }
        } else {
            decision = flowDecisionCoordinator.failOpen(.unsupportedRemoteEndpoint)
        }
        return observeWithoutIntercepting(decision)
    }

    @available(macOS, introduced: 14.0, obsoleted: 15.0)
    override func __handleNewUDPFlow(
        _ flow: NEAppProxyUDPFlow,
        initialRemoteEndpoint remoteEndpoint: NetworkExtension.__NWEndpoint
    ) -> Bool {
        let plan = flowDecisionCoordinator.planLegacyUDPFlow(
            flow,
            initialRemoteEndpoint: remoteEndpoint
        )
        return handleUDPFlow(flow, plan: plan)
    }

    private func handleUDPFlow(
        _ flow: NEAppProxyUDPFlow,
        plan: UDPFlowInterceptionPlan
    ) -> Bool {
        activities.upsert(plan.activity)
        switch plan.decision.disposition {
        case .direct, .failOpen:
            return false
        case .reject:
            let completion: @Sendable (Error?) -> Void = { error in
                let rejection = error ?? NSError(
                    domain: "one.leaper.mclash.network-extension",
                    code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "Datagram flow rejected by MClash rule"]
                )
                flow.closeReadWithError(rejection)
                flow.closeWriteWithError(rejection)
            }
            AppProxyFlowCompatibility.open(flow, completion: completion)
            return true
        case let .mihomo(route):
            guard route == .profileRules,
                  plan.initialDestination != nil,
                  let proxy = plan.proxy
            else {
                // A generic listener cannot faithfully implement a forced
                // global/group route. Leave the flow untouched until a
                // route-specific mihomo listener is configured.
                recordUnsupportedRoute(plan.activity)
                return false
            }
            markRelayConnecting(plan.activity.flowIdentifier)
            udpRelays.start(
                flow: flow,
                proxy: proxy,
                activityObserver: relayObserver(for: plan.activity.flowIdentifier)
            )
            return true
        }
    }

    private func observeWithoutIntercepting(_ decision: FlowTrafficDecision) -> Bool {
        // Returning false is the documented transparent-provider path for
        // preserving the original connection when a flow is not owned.
        _ = decision
        return false
    }

    private static func transparentProxyNetworkSettings() -> NETransparentProxyNetworkSettings {
        let settings = NETransparentProxyNetworkSettings(
            tunnelRemoteAddress: "127.0.0.1"
        )
        settings.includedNetworkRules = [allOutboundNetworkRule()]
        return settings
    }

    private static func allOutboundNetworkRule() -> NENetworkRule {
        if #available(macOS 15.0, *) {
            return NENetworkRule(
                remoteNetworkEndpoint: nil,
                remotePrefix: 0,
                localNetworkEndpoint: nil,
                localPrefix: 0,
                protocol: .any,
                direction: .outbound
            )
        }
        return NENetworkRule(
            __remoteNetwork: nil,
            remotePrefix: 0,
            localNetwork: nil,
            localPrefix: 0,
            protocol: .any,
            direction: .outbound
        )
    }

    private static func invalidBootstrapConfigurationError() -> Error {
        NSError(
            domain: "one.leaper.mclash.network-extension",
            code: 3,
            userInfo: [
                NSLocalizedDescriptionKey:
                    "The capture snapshot or local Mihomo SOCKS endpoint is invalid"
            ]
        )
    }

    override func handleAppMessage(
        _ messageData: Data,
        completionHandler: ((Data?) -> Void)? = nil
    ) {
        let response: ProviderControlResponse
        do {
            let request = try ProviderControlCodec.decode(messageData)
            switch request.command {
            case .status:
                response = runtime.apply(request)
            case .activity:
                let snapshot = runtime.apply(request)
                let batch = activities.batch(
                    after: request.activityCursor ?? 0,
                    limit: min(max(request.activityLimit ?? 200, 1), 500)
                )
                response = ProviderControlResponse(
                    protocolVersion: snapshot.protocolVersion,
                    accepted: snapshot.accepted,
                    provider: snapshot.provider,
                    revision: snapshot.revision,
                    running: snapshot.running,
                    captureEnabled: snapshot.captureEnabled,
                    failOpen: snapshot.failOpen,
                    message: snapshot.message,
                    activityBatch: batch
                )
            case .clearActivity:
                activities.removeAll()
                response = runtime.apply(request)
            case .quiesce:
                flowDecisionCoordinator.quiesce()
                response = runtime.apply(request)
            case .applyConfiguration:
                let configuration = providerConfiguration(from: request)
                guard flowDecisionCoordinator.validates(configuration: configuration) else {
                    let snapshot = runtime.snapshot(
                        message: "Invalid capture snapshot or mihomo SOCKS endpoint"
                    )
                    response = ProviderControlResponse(
                        protocolVersion: ProviderControlRequest.currentProtocolVersion,
                        accepted: false,
                        provider: snapshot.provider,
                        revision: snapshot.revision,
                        running: snapshot.running,
                        captureEnabled: false,
                        failOpen: true,
                        message: snapshot.message,
                        activityBatch: nil
                    )
                    completionHandler?(ProviderControlCodec.encode(response))
                    return
                }
                response = runtime.apply(request)
                if response.accepted {
                    flowDecisionCoordinator.load(configuration: configuration)
                }
            }
        } catch {
            let snapshot = runtime.snapshot(message: "Invalid provider message: \(error)")
            response = ProviderControlResponse(
                protocolVersion: ProviderControlRequest.currentProtocolVersion,
                accepted: false,
                provider: snapshot.provider,
                revision: snapshot.revision,
                running: snapshot.running,
                captureEnabled: snapshot.captureEnabled,
                failOpen: snapshot.failOpen,
                message: snapshot.message,
                activityBatch: nil
            )
        }
        completionHandler?(ProviderControlCodec.encode(response))
    }

    private func providerConfiguration(
        from request: ProviderControlRequest
    ) -> [String: Any] {
        var configuration: [String: Any] = [:]
        if let revision = request.revision {
            configuration[ProviderConfigurationKey.revision] = revision
        }
        if let captureEnabled = request.captureEnabled {
            configuration[ProviderConfigurationKey.captureEnabled] = captureEnabled
        }
        if let failOpen = request.failOpen {
            configuration[ProviderConfigurationKey.failOpen] = failOpen
        }
        if let snapshot = request.captureConfigurationSnapshot {
            configuration[ProviderConfigurationKey.captureConfigurationSnapshot] = snapshot
        }
        if let host = request.mihomoSOCKSHost {
            configuration[ProviderConfigurationKey.mihomoSOCKSHost] = host
        }
        if let port = request.mihomoSOCKSPort {
            configuration[ProviderConfigurationKey.mihomoSOCKSPort] = port
        }
        if let username = request.mihomoSOCKSUsername {
            configuration[ProviderConfigurationKey.mihomoSOCKSUsername] = username
        }
        if let password = request.mihomoSOCKSPassword {
            configuration[ProviderConfigurationKey.mihomoSOCKSPassword] = password
        }
        return configuration
    }

    private func markRelayConnecting(_ flowIdentifier: UUID) {
        guard var activity = activities.activity(for: flowIdentifier) else { return }
        activity.relayState = .connecting
        activity.endedAt = nil
        activities.upsert(activity)
    }

    private func recordUnsupportedRoute(_ original: AppRoutingActivity) {
        guard var activity = activities.activity(for: original.flowIdentifier) else { return }
        activity.effectiveAction = .direct
        activity.relayState = .notApplicable
        activity.relayError = "This Mihomo route requires a route-specific listener; traffic was left direct."
        activity.endedAt = Date()
        activities.upsert(activity)
    }

    private func relayObserver(
        for flowIdentifier: UUID
    ) -> @Sendable (AppRoutingRelaySnapshot) -> Void {
        let activities = activities
        return { snapshot in
            guard var activity = activities.activity(for: flowIdentifier) else { return }
            activity.relayState = snapshot.state
            activity.relayError = snapshot.error
            activity.uploadBytes = snapshot.uploadBytes
            activity.downloadBytes = snapshot.downloadBytes
            activity.relayLocalPort = snapshot.localPort
            switch snapshot.state {
            case .completed, .failed:
                activity.endedAt = Date()
            case .notApplicable, .pending, .connecting, .ready, .relaying:
                activity.endedAt = nil
            }
            activities.upsert(activity)
        }
    }

    override func sleep(completionHandler: @escaping () -> Void) {
        tcpRelays.cancelAll()
        udpRelays.cancelAll()
        completionHandler()
    }

    override func wake() {
        // Configuration remains revisioned and quiesced by the host when the
        // backend is unavailable. Nothing needs to be reasserted in the shell.
    }
}

private final class ProxyStartCompletion: @unchecked Sendable {
    private let completion: (Error?) -> Void

    init(_ completion: @escaping (Error?) -> Void) {
        self.completion = completion
    }

    func call(_ error: Error?) {
        completion(error)
    }
}

@available(macOS 15.0, *)
extension TransparentProxyProvider: NEAppProxyUDPFlowHandling {
    func handleNewUDPFlow(
        _ flow: NEAppProxyUDPFlow,
        initialRemoteFlowEndpoint remoteEndpoint: Network.NWEndpoint
    ) -> Bool {
        let plan = flowDecisionCoordinator.planUDPFlow(
            flow,
            initialRemoteEndpoint: remoteEndpoint
        )
        return handleUDPFlow(flow, plan: plan)
    }
}
