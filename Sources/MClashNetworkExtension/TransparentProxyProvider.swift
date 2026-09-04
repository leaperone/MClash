import Foundation
import MClashNetworkShared
import OSLog
@preconcurrency import Network
@preconcurrency import NetworkExtension

private let appRoutingFlowLogger = Logger(
    subsystem: "one.leaper.mclash.network-extension",
    category: "AppRouting.Flow"
)

/// Transparent application proxy entry point. The framework first sends all
/// outbound TCP/UDP flows (except loopback) to this provider. Direct and true
/// fail-open decisions are handed back to macOS immediately so they keep the
/// original kernel-managed network path. Only reject and Mihomo routes are
/// owned; an already-owned Mihomo flow may still use the Direct relay as a
/// fail-open fallback because returning it to macOS is no longer possible.
final class TransparentProxyProvider: NETransparentProxyProvider, @unchecked Sendable {
    private let runtime = ProviderRuntimeState(providerName: "transparent-proxy")
    private let flowDecisionCoordinator = NetworkExtensionFlowDecisionCoordinator()
    private let tcpRelays = TCPFlowRelayRegistry()
    private let hysteria2Relays = Hysteria2RelayRegistry()
    private let udpSessions = UDPFlowSessionRegistry()
    private let activities = AppRoutingActivityRing(capacity: 2_000)
    /// Native socket entrances are an explicit opt-in bridge. In the normal
    /// configuration this manager remains empty and Mihomo's listener path is
    /// untouched.
    private let nativeInboundListeners = NativeInboundListenerManager(
        routeResolver: { spec, _ in
            switch spec.route {
            case .direct: .direct
            case .reject: .reject
            case .outbound: .reject // no silent proxy-to-Direct fallback
            }
        },
        connector: NativeInboundDirectConnector()
    )

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
        Self.prepareDNSRegistry(from: configuration)
        if let error = configureNativeInboundListeners(from: configuration) {
            nativeInboundListeners.stop()
            runtime.stop()
            completionHandler(error)
            return
        }
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
        hysteria2Relays.cancelAll()
        udpSessions.cancelAll()
        nativeInboundListeners.stop()
        runtime.stop()
        completionHandler()
    }

    override func handleNewFlow(_ flow: NEAppProxyFlow) -> Bool {
        guard InitialFlowOwnershipPolicy.shouldEvaluate(
            metadataSigningIdentifier: flow.metaData.sourceAppSigningIdentifier
        ) else { return false }

        let decision: FlowTrafficDecision
        if let tcpFlow = flow as? NEAppProxyTCPFlow {
            let plan = flowDecisionCoordinator.planTCPFlow(tcpFlow)
            let activity = Self.annotatedActivity(plan.activity)
            activities.upsert(activity)
            Self.logDecision(activity)
            decision = plan.decision
            guard InitialFlowOwnershipPolicy.owns(decision.disposition) else {
                return false
            }
            switch decision.disposition {
            case .direct:
                // Kept as a defensive fallback if the ownership policy gains
                // a new exception without this switch being updated.
                return false
            case .failOpen:
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
            case .outbound:
                // Native node connectors are independent from the legacy
                // loopback Mihomo SOCKS listener. Use the original endpoint
                // for their protocol handshake and allow a nil proxy.
                // Hysteria2 has a QUIC/HTTP3 handshake and cannot be sent
                // through the SOCKS5-oriented TCPFlowRelay. Keep it as a
                // provider-owned native path, with fallback before the
                // intercepted flow is opened if authentication fails.
                if let target = plan.nativeTarget,
                   NativeConnectorRegistry.kind(for: target) == .hysteria2,
                   Self.nativeHysteria2OptIn {
                    startNativeHysteria2TCP(
                        flow: tcpFlow,
                        plan: plan,
                        target: target
                    )
                    return true
                }

                let destination: SOCKS5Endpoint
                if plan.nativeConnector != nil {
                    guard let nativeDestination = plan.destination else {
                        return handleUnavailableMihomoTCPRoute(tcpFlow, plan: plan)
                    }
                    destination = nativeDestination
                } else {
                    guard let legacyDestination = plan.mihomoDestination,
                          plan.proxy != nil else {
                        return handleUnavailableMihomoTCPRoute(tcpFlow, plan: plan)
                    }
                    destination = legacyDestination
                }
                markRelayConnecting(plan.activity.flowIdentifier)
                tcpRelays.startProxy(
                    flow: tcpFlow,
                    proxy: plan.proxy,
                    destination: destination,
                    directFallbackDestination: plan.destination,
                    unavailableFallback: plan.unavailableFallback,
                    outboundConnector: plan.nativeConnector,
                    initialPayload: plan.nativeInitialPayload,
                    usesSOCKS5Handshake: plan.nativeUsesSOCKS5Handshake,
                    activityObserver: relayObserver(for: plan.activity.flowIdentifier)
                )
                return true
            }
        } else {
            decision = flowDecisionCoordinator.failOpen(.unsupportedRemoteEndpoint)
        }
        return observeWithoutIntercepting(decision)
    }

    private func startNativeHysteria2TCP(
        flow: NEAppProxyTCPFlow,
        plan: TCPFlowInterceptionPlan,
        target: OutboundNodeTarget
    ) {
        let flowID = plan.activity.flowIdentifier
        let connector = NativeHysteria2OutboundConnector(target: target)
        let session = Hysteria2QUICSession(connector: connector)
        hysteria2Relays.retain(session: session, for: flowID)
        session.start { [weak self, weak flow] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                self.hysteria2Relays.release(flowID: flowID)
                guard let flow else { return }
                self.handleNativeHysteria2Failure(
                    flow: flow,
                    plan: plan,
                    error: error
                )
            case .success:
                guard let destination = plan.destination else {
                    self.hysteria2Relays.release(flowID: flowID)
                    if let flow {
                        self.handleNativeHysteria2Failure(
                            flow: flow,
                            plan: plan,
                            error: TCPFlowRelayError.upstreamClosedDuringHandshake
                        )
                    }
                    return
                }
                guard let flow else {
                    self.hysteria2Relays.release(flowID: flowID)
                    return
                }
                session.openTCPStream(to: destination) { [weak self, weak flow] openResult in
                    guard let self else { return }
                    switch openResult {
                    case .failure(let error):
                        self.hysteria2Relays.release(flowID: flowID)
                        guard let flow else { return }
                        self.handleNativeHysteria2Failure(
                            flow: flow,
                            plan: plan,
                            error: error
                        )
                    case let .success(connection):
                        guard let flow else {
                            self.hysteria2Relays.release(flowID: flowID)
                            return
                        }
                        let relay = Hysteria2TCPStreamRelay(
                            flow: flow,
                            connection: connection,
                            completion: { [weak self] in
                                self?.hysteria2Relays.release(flowID: flowID)
                            }
                        )
                        self.hysteria2Relays.retain(tcp: relay, for: flowID)
                        relay.start()
                    }
                }
            }
        }
    }

    private func handleNativeHysteria2Failure(
        flow: NEAppProxyTCPFlow,
        plan: TCPFlowInterceptionPlan,
        error: Error
    ) {
        switch plan.unavailableFallback {
        case .direct:
            guard let destination = plan.destination else {
                flow.closeReadWithError(error)
                flow.closeWriteWithError(error)
                return
            }
            tcpRelays.startDirect(
                flow: flow,
                destination: destination,
                relayNote: "Hysteria2 native connection failed before application payload forwarding; MClash used the rule's Direct fallback. \(error.localizedDescription)",
                activityObserver: relayObserver(for: plan.activity.flowIdentifier)
            )
        case .reject:
            flow.closeReadWithError(error)
            flow.closeWriteWithError(error)
        }
    }

    /// Hysteria2's HTTP/3 stream multiplexing still needs real endpoint
    /// interoperability coverage before it can become the default data path.
    /// Keep production on the proven compatibility connector until an
    /// explicit test build opts in.
    private static var nativeHysteria2OptIn: Bool {
        ProcessInfo.processInfo.environment["MCLASH_NATIVE_HYSTERIA2"] == "1"
    }

    @available(macOS, introduced: 14.0, obsoleted: 15.0)
    override func __handleNewUDPFlow(
        _ flow: NEAppProxyUDPFlow,
        initialRemoteEndpoint remoteEndpoint: NetworkExtension.__NWEndpoint
    ) -> Bool {
        guard InitialFlowOwnershipPolicy.shouldEvaluate(
            metadataSigningIdentifier: flow.metaData.sourceAppSigningIdentifier
        ) else { return false }

        let parentFlowIdentifier = UUID()
        let plan = flowDecisionCoordinator.planLegacyUDPFlow(
            flow,
            initialRemoteEndpoint: remoteEndpoint,
            parentFlowIdentifier: parentFlowIdentifier
        )
        return handleUDPFlow(
            flow,
            plan: plan,
            parentFlowIdentifier: parentFlowIdentifier
        )
    }

    private func handleUDPFlow(
        _ flow: NEAppProxyUDPFlow,
        plan: UDPFlowInterceptionPlan,
        parentFlowIdentifier: UUID
    ) -> Bool {
        let activity = Self.annotatedActivity(plan.activity)
        activities.upsert(activity)
        Self.logDecision(activity)
        // A Direct initial UDP decision stays on the original macOS path.
        // Per-destination Direct fallback remains available only inside a flow
        // that was already owned by a Mihomo/reject decision.
        guard InitialFlowOwnershipPolicy.owns(plan.decision.disposition) else {
            return false
        }

        guard plan.initialDestination != nil else {
            recordUDPDirectRelayUnavailable(plan.activity)
            return false
        }
        let coordinator = flowDecisionCoordinator
        let activities = activities
        let started = udpSessions.start(
            id: parentFlowIdentifier,
            flow: flow,
            initialPlan: plan,
            planner: { destination in
                coordinator.planUDPDatagram(
                    flow,
                    destination: destination,
                    parentFlowIdentifier: parentFlowIdentifier
                )
            },
            revisionProvider: {
                coordinator.currentRevision()
            },
            activitySink: { activity in
                activities.upsert(Self.annotatedActivity(activity))
            },
            observerFactory: { identifier in
                Self.relayObserver(
                    activities: activities,
                    flowIdentifier: identifier
                )
            }
        )
        guard started else {
            recordUDPAdmissionFailure(plan.activity, flow: flow)
            return true
        }
        return true
    }

    /// Adds a durable, user-visible explanation when the provider had to use
    /// NetworkExtension's flow metadata instead of resolved process details.
    /// No audit token, full path, destination, or other sensitive material is
    /// copied into the note.
    private static func annotatedActivity(
        _ original: AppRoutingActivity
    ) -> AppRoutingActivity {
        var activity = original
        guard activity.relayNote == nil else { return activity }
        let usedKernelFlowMetadata = activity.source.processIdentifier <= 0
        let usedDefaultDirect: Bool
        if case let .rule(cause) = activity.cause,
           case .defaultDirect = cause {
            usedDefaultDirect = true
        } else {
            usedDefaultDirect = false
        }

        if usedKernelFlowMetadata && usedDefaultDirect {
            activity.relayNote = "Process details were unavailable, so rules were evaluated using macOS flow metadata and destination information. No rule matched; macOS kept the original Direct connection and its payload was not measured."
        } else if usedKernelFlowMetadata {
            activity.relayNote = "Process details were unavailable; the rule was evaluated using macOS flow metadata and destination information."
        } else if usedDefaultDirect {
            activity.relayNote = "No enabled App Routing rule matched; macOS kept the original Direct connection and its payload was not measured."
        } else if activity.effectiveAction == .direct,
                  activity.relayState == .notApplicable {
            activity.relayNote = "macOS kept the original Direct connection; its payload was not measured by MClash."
        }
        return activity
    }

    /// Emits only exceptional fail-open decisions. Normal decisions already
    /// live in the bounded activity ring; formatting and privacy-hashing a
    /// Unified Logging record for every short connection adds avoidable work to
    /// the synchronous admission path.
    private static func logDecision(_ activity: AppRoutingActivity) {
        guard case .failOpen = activity.effectiveAction else { return }
        let sourceMode = activity.source.processIdentifier > 0
            ? "resolved-process"
            : "kernel-flow-metadata"
        let processName = activity.source.executablePath.map {
            URL(fileURLWithPath: $0).lastPathComponent
        } ?? activity.source.signingIdentifier ?? activity.source.bundleIdentifier ?? "unknown"
        let destination = activity.destination.hostname
            ?? activity.destination.ipAddress
            ?? "unknown"
        let disposition = diagnosticDisposition(activity.effectiveAction)
        let reason = diagnosticReason(activity.cause)
        let rule = activity.matchedRuleIdentifier ?? "none"
        let flow = String(activity.flowIdentifier.uuidString.prefix(8))
        let transport = activity.transportProtocol.rawValue

        appRoutingFlowLogger.error(
            "decision flow=\(flow, privacy: .public) protocol=\(transport, privacy: .public) source=\(sourceMode, privacy: .public) disposition=\(disposition, privacy: .public) reason=\(reason, privacy: .public) pid=\(activity.source.processIdentifier, privacy: .public) process=\(processName, privacy: .private(mask: .hash)) destination=\(destination, privacy: .private(mask: .hash)) port=\(activity.destination.port, privacy: .public) rule=\(rule, privacy: .private(mask: .hash))"
        )
    }

    private static func diagnosticDisposition(_ disposition: FlowTrafficDisposition) -> String {
        switch disposition {
        case .direct: "direct"
        case .reject: "reject"
        case .outbound: "outbound"
        case .failOpen: "fail-open"
        }
    }

    private static func diagnosticReason(_ reason: FlowTrafficDecisionReason) -> String {
        switch reason {
        case .captureDisabled:
            "capture-disabled"
        case .configurationUnavailable:
            "configuration-unavailable"
        case .contextUnavailable:
            "context-unavailable"
        case let .rule(cause):
            diagnosticRuleCause(cause)
        case .outboundUnavailable:
            "mihomo-route-unavailable"
        }
    }

    private static func diagnosticRuleCause(_ cause: RuleDecisionCause) -> String {
        switch cause {
        case .matchedRule: "matched-rule"
        case let .builtInBypass(reason): "built-in-\(reason.rawValue)"
        case .defaultDirect: "default-direct"
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
            case .prepareDNS:
                let snapshot = runtime.apply(request)
                guard snapshot.accepted,
                      snapshot.running,
                      let revision = request.revision,
                      revision == snapshot.revision,
                      let activationIdentifier = request.activationIdentifier,
                      let payload = request.dnsProxyBootstrap,
                      let bootstrap = try? DNSProxyBootstrapConfiguration.decode(payload),
                      bootstrap.revision == revision,
                      bootstrap.activationIdentifier == activationIdentifier,
                      DNSProxyRuntimeRegistry.shared.prepare(bootstrap)
                else {
                    response = Self.response(
                        from: snapshot,
                        accepted: false,
                        message: "DNS activation preparation requires the active revision and an activation identifier"
                    )
                    break
                }
                response = snapshot
            case .dnsStatus:
                let snapshot = runtime.apply(request)
                response = Self.response(
                    from: snapshot,
                    dnsRuntimeReport: DNSProxyRuntimeRegistry.shared.snapshot()
                )
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
                    activityBatch: batch,
                    dnsRuntimeReport: nil
                )
            case .clearActivity:
                activities.removeHistory()
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
                        activityBatch: nil,
                        dnsRuntimeReport: nil
                    )
                    completionHandler?(ProviderControlCodec.encode(response))
                    return
                }
                response = runtime.apply(request)
                if response.accepted {
                    flowDecisionCoordinator.load(configuration: configuration)
                    Self.prepareDNSRegistry(from: configuration)
                    _ = configureNativeInboundListeners(from: configuration)
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
                activityBatch: nil,
                dnsRuntimeReport: nil
            )
        }
        completionHandler?(ProviderControlCodec.encode(response))
    }

    private static func response(
        from snapshot: ProviderControlResponse,
        accepted: Bool? = nil,
        message: String? = nil,
        dnsRuntimeReport: DNSProxyRuntimeReport? = nil
    ) -> ProviderControlResponse {
        ProviderControlResponse(
            protocolVersion: snapshot.protocolVersion,
            accepted: accepted ?? snapshot.accepted,
            provider: snapshot.provider,
            revision: snapshot.revision,
            running: snapshot.running,
            captureEnabled: snapshot.captureEnabled,
            failOpen: snapshot.failOpen,
            message: message ?? snapshot.message,
            activityBatch: nil,
            dnsRuntimeReport: dnsRuntimeReport
        )
    }

    private func providerConfiguration(
        from request: ProviderControlRequest
    ) -> [String: Any] {
        var configuration: [String: Any] = [:]
        if let revision = request.revision {
            configuration[ProviderConfigurationKey.revision] = revision
        }
        if let activationIdentifier = request.activationIdentifier {
            configuration[ProviderConfigurationKey.activationIdentifier] =
                activationIdentifier.uuidString
        }
        if let dnsProxyBootstrap = request.dnsProxyBootstrap {
            configuration[ProviderConfigurationKey.dnsProxyBootstrap] = dnsProxyBootstrap
        }
        if let captureEnabled = request.captureEnabled {
            configuration[ProviderConfigurationKey.captureEnabled] = captureEnabled
        }
        if let failOpen = request.failOpen {
            configuration[ProviderConfigurationKey.failOpen] = failOpen
        }
        if let backend = request.captureBackend {
            configuration[ProviderConfigurationKey.captureBackend] = backend.rawValue as NSString
        }
        if let snapshot = request.captureConfigurationSnapshot {
            configuration[ProviderConfigurationKey.captureConfigurationSnapshot] = snapshot
        }
        if let catalog = request.mihomoRouteProxyCatalog {
            configuration[ProviderConfigurationKey.mihomoRouteProxyCatalog] = catalog
        }
        if let catalog = request.outboundNodeTargetCatalog {
            configuration[ProviderConfigurationKey.outboundNodeTargetCatalog] = catalog
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

    private static func prepareDNSRegistry(from configuration: [String: Any]?) {
        guard let configuration,
              let payload = data(
                  configuration[ProviderConfigurationKey.dnsProxyBootstrap]
              ),
              let bootstrap = try? DNSProxyBootstrapConfiguration.decode(payload)
        else {
            return
        }
        _ = DNSProxyRuntimeRegistry.shared.prepare(bootstrap)
    }

    /// Starts native HTTP/SOCKS listeners only when both an explicit boolean
    /// and a valid encoded registry are delivered. Missing or disabled data
    /// leaves the existing Mihomo listener lifecycle completely unchanged.
    @discardableResult
    private func configureNativeInboundListeners(from configuration: [String: Any]?) -> Error? {
        nativeInboundListeners.stop()
        let enabled = Self.nativeInboundBool(configuration?[ProviderConfigurationKey.nativeInboundListenersEnabled]) ?? false
        guard enabled else { return nil }
        guard let data = Self.data(configuration?[ProviderConfigurationKey.nativeInboundListenerRegistry]),
              let registry = try? MClashListenerRegistry.decode(data)
        else {
            return NSError(
                domain: "one.leaper.mclash.network-extension",
                code: 8,
                userInfo: [NSLocalizedDescriptionKey: "Native inbound listener registry is invalid"]
            )
        }
        do {
            let outboundCatalog = Self.data(
                configuration?[ProviderConfigurationKey.outboundNodeTargetCatalog]
            ).flatMap { try? OutboundNodeTargetCatalog.decode($0) }
            let outboundConnector: (any MClashInboundOutboundConnector)? = outboundCatalog.map {
                NativeInboundCatalogConnector(catalog: $0)
            }
            try nativeInboundListeners.configure(
                registry,
                outboundCatalog: outboundCatalog,
                outboundConnector: outboundConnector
            )
            nativeInboundListeners.start()
            return nil
        } catch {
            return error
        }
    }

    private static func data(_ value: Any?) -> Data? {
        switch value {
        case let value as Data: value
        case let value as NSData: value as Data
        default: nil
        }
    }

    private static func nativeInboundBool(_ value: Any?) -> Bool? {
        switch value {
        case let value as Bool: value
        case let value as NSNumber: value.boolValue
        default: nil
        }
    }

    private func markRelayConnecting(_ flowIdentifier: UUID) {
        guard var activity = activities.activity(for: flowIdentifier) else { return }
        activity.relayState = .connecting
        activity.payloadBytesAreMeasured = true
        activity.endedAt = nil
        activities.upsert(activity)
    }

    private func recordUDPDirectRelayUnavailable(_ original: AppRoutingActivity) {
        guard var activity = activities.activity(for: original.flowIdentifier) else { return }
        activity.relayState = .failed
        activity.relayError = "The original UDP destination could not be converted for direct relay; traffic was left to macOS."
        activity.endedAt = Date()
        activities.upsert(activity)
    }

    private func recordUDPAdmissionFailure(
        _ original: AppRoutingActivity,
        flow: NEAppProxyUDPFlow
    ) {
        let error = NSError(
            domain: "one.leaper.mclash.network-extension",
            code: 6,
            userInfo: [
                NSLocalizedDescriptionKey:
                    "App Routing reached its active UDP flow safety limit"
            ]
        )
        guard var activity = activities.activity(for: original.flowIdentifier) else { return }
        activity.relayState = .failed
        activity.relayError = error.localizedDescription
        activity.endedAt = Date()
        activities.upsert(activity)
        AppProxyFlowCompatibility.open(flow) { completionError in
            let terminalError = completionError ?? error
            flow.closeReadWithError(terminalError)
            flow.closeWriteWithError(terminalError)
        }
    }

    private func recordDirectRelayUnavailable(_ original: AppRoutingActivity) {
        guard var activity = activities.activity(for: original.flowIdentifier) else { return }
        activity.relayState = .failed
        activity.relayError = "The original TCP destination could not be converted for direct relay; traffic was left to macOS."
        activity.endedAt = Date()
        activities.upsert(activity)
    }

    private func handleUnavailableMihomoTCPRoute(
        _ flow: NEAppProxyTCPFlow,
        plan: TCPFlowInterceptionPlan
    ) -> Bool {
        switch plan.unavailableFallback {
        case .direct:
            guard let destination = plan.destination else {
                recordDirectRelayUnavailable(plan.activity)
                return false
            }
            markRelayConnecting(plan.activity.flowIdentifier)
            tcpRelays.startDirect(
                flow: flow,
                destination: destination,
                relayNote: "The configured Mihomo route has no route-specific listener; MClash used the rule's Direct fallback.",
                activityObserver: relayObserver(for: plan.activity.flowIdentifier)
            )
            return true
        case .reject:
            let error = NSError(
                domain: "one.leaper.mclash.network-extension",
                code: 4,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "The selected Mihomo route is unavailable and this rule rejects fallback"
                ]
            )
            AppProxyFlowCompatibility.open(flow) { completionError in
                let rejection = completionError ?? error
                flow.closeReadWithError(rejection)
                flow.closeWriteWithError(rejection)
            }
            guard var activity = activities.activity(for: plan.activity.flowIdentifier) else {
                return true
            }
            activity.effectiveAction = .reject
            activity.relayState = .failed
            activity.relayError = error.localizedDescription
            activity.endedAt = Date()
            activities.upsert(activity)
            return true
        }
    }

    private func relayObserver(
        for flowIdentifier: UUID
    ) -> @Sendable (AppRoutingRelaySnapshot) -> Void {
        Self.relayObserver(
            activities: activities,
            flowIdentifier: flowIdentifier
        )
    }

    private static func relayObserver(
        activities: AppRoutingActivityRing,
        flowIdentifier: UUID
    ) -> @Sendable (AppRoutingRelaySnapshot) -> Void {
        return { snapshot in
            guard var activity = activities.activity(for: flowIdentifier) else { return }
            activity.relayState = snapshot.state
            activity.relayError = snapshot.error
            if let note = snapshot.note {
                activity.relayNote = note
            }
            activity.uploadBytes = snapshot.uploadBytes
            activity.downloadBytes = snapshot.downloadBytes
            activity.relayLocalPort = snapshot.localPort
            if let value = snapshot.uploadDatagrams {
                activity.uploadDatagrams = value
            }
            if let value = snapshot.downloadDatagrams {
                activity.downloadDatagrams = value
            }
            if let value = snapshot.droppedDatagrams {
                activity.droppedDatagrams = value
            }
            if let value = snapshot.lastPayloadAt {
                activity.lastPayloadAt = value
            }
            if let effectiveAction = snapshot.effectiveAction {
                activity.effectiveAction = effectiveAction
                if effectiveAction == .direct {
                    activity.payloadBytesAreMeasured = true
                }
            }
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
        udpSessions.cancelAll()
        nativeInboundListeners.stop()
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
        guard InitialFlowOwnershipPolicy.shouldEvaluate(
            metadataSigningIdentifier: flow.metaData.sourceAppSigningIdentifier
        ) else { return false }

        let parentFlowIdentifier = UUID()
        let plan = flowDecisionCoordinator.planUDPFlow(
            flow,
            initialRemoteEndpoint: remoteEndpoint,
            parentFlowIdentifier: parentFlowIdentifier
        )
        return handleUDPFlow(
            flow,
            plan: plan,
            parentFlowIdentifier: parentFlowIdentifier
        )
    }
}
