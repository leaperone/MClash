import Foundation
import MClashNetworkShared
import Network
import NetworkExtension

/// Process-wide, bounded DNS attribution state shared by the DNS and
/// transparent providers. The store is memory-only and is cleared whenever a
/// provider lifecycle or capture generation changes.
final class DNSResolutionAssociationRegistry: @unchecked Sendable {
    static let shared = DNSResolutionAssociationRegistry()
    let store = DNSResolutionAssociationStore()
    private init() {}
    func clear() { store.removeAll() }
}

enum InitialFlowOwnershipPolicy {
    static func shouldEvaluate(metadataSigningIdentifier: String) -> Bool {
        !TrustedMClashComponentPolicy().contains(
            metadataSigningIdentifier: metadataSigningIdentifier
        )
    }

    /// Returning `false` from an NE transparent provider preserves the original
    /// application connection. Direct must therefore never be owned merely for
    /// byte accounting; doing so adds a second socket and a user-space relay to
    /// traffic that explicitly requested the native network path.
    static func owns(_ disposition: FlowTrafficDisposition) -> Bool {
        switch disposition {
        case .direct, .failOpen:
            false
        case .reject, .outbound:
            true
        }
    }
}

enum MihomoRouteAvailabilityPolicy {
    /// Availability is route-specific. Treating one live listener (normally
    /// Profile Rules) as proof that every group/global listener exists can turn
    /// a requested Direct fallback into an unnecessary owned relay.
    static func resolve(
        _ decision: FlowTrafficDecision,
        availableRoutes: Set<MihomoRoute>,
        rulesByIdentifier: [String: CaptureRule]
    ) -> FlowTrafficDecision {
        guard case let .outbound(route) = decision.disposition,
              !availableRoutes.contains(route),
              case let .rule(cause) = decision.reason else {
            return decision
        }
        let fallback: UnavailableFallback
        if case let .matchedRule(identifier) = cause,
           let rule = rulesByIdentifier[identifier] {
            fallback = rule.unavailableFallback
        } else {
            fallback = .direct
        }
        let disposition: FlowTrafficDisposition = switch fallback {
        case .direct: .direct
        case .reject: .reject
        }
        return FlowTrafficDecision(
            disposition: disposition,
            reason: .outboundUnavailable(rule: cause, fallback: fallback),
            ruleEvidence: decision.ruleEvidence
        )
    }
}

enum DNSProfileRoutingRulePolicy {
    /// A DNS proxy flow exposes the resolver endpoint, not the hostname the
    /// source application is resolving. Only a source-scoped rule with no
    /// destination or port constraint may select an explicit Profile here.
    /// Filtering before evaluation prevents a higher-priority resolver-IP or
    /// port-53 rule from shadowing a later application rule.
    static func eligible(_ rule: CaptureRule) -> Bool {
        guard rule.enabled,
              !rule.sources.isEmpty,
              rule.destinations.isEmpty,
              rule.portRanges.isEmpty,
              case let .outbound(route) = rule.action,
              route.routingProfileID != nil else {
            return false
        }
        return true
    }
}

final class NetworkExtensionFlowDecisionCoordinator: @unchecked Sendable {
    private struct State: Sendable {
        var revision: UInt64 = 0
        var generation: UUID = UUID()
        var captureEnabled = false
        var preparedConfiguration = PreparedCaptureConfiguration(
            .failOpen(.missingEncodedSnapshot)
        )
        var dnsPreparedConfiguration = PreparedCaptureConfiguration(
            .failOpen(.missingEncodedSnapshot)
        )
        var mihomoSOCKSConfigurations: [MihomoRoute: ProviderSOCKSConfiguration] = [:]
        var availableMihomoRoutes: Set<MihomoRoute> = []
        var outboundNodeTargets: OutboundNodeTargetCatalog?
        /// Presence of the connector-neutral catalog selects native mode.
        /// Legacy Mihomo route catalogs are ignored for native decisions.
        var nativeMode = false
        var rulesByIdentifier: [String: CaptureRule] = [:]
        var dnsRulesByIdentifier: [String: CaptureRule] = [:]
    }

    private let lock = NSLock()
    private let identityResolver = ProcessIdentityResolver()
    private let identityCache = ProcessIdentityResolutionCache(capacity: 256)
    private let trustedComponentPolicy = TrustedMClashComponentPolicy()
    private let contextBuilder = FlowContextBuilder()
    private let decisionAdapter = FlowTrafficDecisionAdapter()
    private let dnsAssociations: DNSResolutionAssociationStore
    private var state = State()

    init(
        dnsAssociations: DNSResolutionAssociationStore =
            DNSResolutionAssociationRegistry.shared.store
    ) {
        self.dnsAssociations = dnsAssociations
    }

    func load(configuration: [String: Any]?) {
        let captureEnabled = Self.bool(
            configuration?[ProviderConfigurationKey.captureEnabled]
        ) ?? false
        let encodedSnapshot = configuration?[
            ProviderConfigurationKey.captureConfigurationSnapshot
        ] as? Data
        let loadResult = CaptureConfigurationSnapshotLoader().load(encodedSnapshot)
        // Compile destination indexes once per provider configuration load,
        // never once per intercepted connection.
        let preparedConfiguration = PreparedCaptureConfiguration(loadResult)
        let dnsRules = loadResult.snapshot?.rules.filter(
            DNSProfileRoutingRulePolicy.eligible
        ) ?? []
        let dnsLoadResult: CaptureConfigurationLoadResult
        if let snapshot = loadResult.snapshot,
           let filteredSnapshot = try? CaptureConfigurationSnapshot(
               revision: snapshot.revision,
               generationID: snapshot.generationID,
               createdAt: snapshot.createdAt,
               rules: dnsRules
           ) {
            dnsLoadResult = .loaded(filteredSnapshot)
        } else {
            dnsLoadResult = loadResult
        }

        lock.lock()
        state.revision = Self.uint64(configuration?[ProviderConfigurationKey.revision]) ?? 0
        state.generation = loadResult.snapshot?.generationID ?? UUID()
        state.captureEnabled = captureEnabled
        state.preparedConfiguration = preparedConfiguration
        state.dnsPreparedConfiguration = PreparedCaptureConfiguration(
            dnsLoadResult
        )
        let routeCatalog = ProviderSOCKSConfiguration.routeCatalog(
            providerConfiguration: configuration
        ) ?? [:]
        let backendMarkerPresent = configuration?[ProviderConfigurationKey.captureBackend] != nil
        let backendMarker = (configuration?[ProviderConfigurationKey.captureBackend] as? String)
            .flatMap(NetworkCaptureBackend.init(rawValue:))
        let nativePayloadPresent = configuration?[ProviderConfigurationKey.outboundNodeTargetCatalog] != nil
        let nativeCatalog = (configuration?[ProviderConfigurationKey.outboundNodeTargetCatalog] as? Data)
            .flatMap { try? OutboundNodeTargetCatalog.decode($0) }
        state.outboundNodeTargets = nativeCatalog
        state.nativeMode = backendMarkerPresent && backendMarker != .legacy
            || backendMarker == .native
            || nativePayloadPresent
        state.mihomoSOCKSConfigurations = routeCatalog
        // Route availability includes connector-neutral node targets. A
        // native SOCKS5 route must not be downgraded to Direct merely because
        // its legacy loopback Mihomo listener entry is absent.
        state.availableMihomoRoutes = Set(routeCatalog.keys).union(
            nativeCatalog?.entries.map(\.route) ?? []
        )
        state.rulesByIdentifier = Dictionary(
            uniqueKeysWithValues: loadResult.snapshot?.rules.map { ($0.id, $0) } ?? []
        )
        state.dnsRulesByIdentifier = Dictionary(
            uniqueKeysWithValues: dnsRules.map { ($0.id, $0) }
        )
        lock.unlock()
    }

    func quiesce() {
        lock.lock()
        state.captureEnabled = false
        lock.unlock()
    }

    func outboundNodeTarget(for route: OutboundRoute) -> OutboundNodeTarget? {
        lock.lock()
        defer { lock.unlock() }
        return state.outboundNodeTargets?.target(for: route)
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
        let backendValue = configuration[ProviderConfigurationKey.captureBackend]
        let backendMarker: NetworkCaptureBackend?
        if let backendValue {
            guard let rawValue = backendValue as? String,
                  let decoded = NetworkCaptureBackend(rawValue: rawValue) else {
                return false
            }
            backendMarker = decoded
        } else {
            backendMarker = nil
        }
        // Native node routes do not need a loopback Mihomo SOCKS catalog.
        // When a native catalog is present it is authoritative: legacy
        // endpoints cannot validate, rescue, or mask an unsupported target.
        let nativePayloadPresent = configuration[ProviderConfigurationKey.outboundNodeTargetCatalog] != nil
        if backendMarker == .native || nativePayloadPresent {
            guard let data = configuration[ProviderConfigurationKey.outboundNodeTargetCatalog] as? Data else {
                return false
            }
            guard let catalog = try? OutboundNodeTargetCatalog.decode(data),
                  !catalog.entries.isEmpty else { return false }
            // Capability is checked for the selected route at flow planning
            // time; unused catalog entries must not prevent provider startup.
            return true
        }
        guard backendMarker != .native else { return false }
        return ProviderSOCKSConfiguration.routeCatalog(
            providerConfiguration: configuration
        ) != nil
    }

    func planTCPFlow(_ flow: NEAppProxyTCPFlow) -> TCPFlowInterceptionPlan {
        let endpoint: FlowRemoteEndpoint
        if #available(macOS 15.0, *) {
            guard let converted = Self.endpoint(flow.remoteFlowEndpoint) else {
                return TCPFlowInterceptionPlan(
                    decision: failOpen(.unsupportedRemoteEndpoint),
                    destination: nil,
                    mihomoDestination: nil,
                    nativeTarget: nil,
                    proxy: nil,
                    nativeConnector: nil,
                    nativeInitialPayload: nil,
                    nativeUsesSOCKS5Handshake: true,
                    connectorCapability: .native,
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
                    mihomoDestination: nil,
                    nativeTarget: nil,
                    proxy: nil,
                    nativeConnector: nil,
                    nativeInitialPayload: nil,
                    nativeUsesSOCKS5Handshake: true,
                    connectorCapability: .native,
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
        let routePlan: ProviderSOCKSFlowPlan? = currentState.nativeMode
            ? nil
            : try? ProviderSOCKSConfiguration.flowPlan(
                for: outcome.decision,
                endpoint: endpoint,
                preferredHostname: outcome.destinationHostname,
                routeCatalog: currentState.mihomoSOCKSConfigurations
            )
        let nativeDestination = try? SOCKS5Endpoint(
            address: SOCKS5Address(domain: endpoint.host),
            port: UInt16(endpoint.port) ?? 0
        )
        // Native connectors use the node-only catalog directly. A missing
        // loopback Mihomo route endpoint must not make this target unusable.
        let nativeTarget: OutboundNodeTarget? = {
            guard currentState.nativeMode else { return nil }
            guard case let .outbound(route) = outcome.decision.disposition else {
                return nil
            }
            return currentState.outboundNodeTargets?.target(for: route)
        }()
        let nativeConnector: (any OutboundConnector)? = {
            guard let target = nativeTarget,
                  NativeConnectorRegistry.supportsNativeTCP(target),
                  let kind = NativeConnectorRegistry.kind(for: target) else { return nil }
            switch kind {
            case .http: return NativeHTTPConnectRelayConnector(target: target)
            case .socks5: return NativeSOCKS5RelayConnector(target: target)
            case .shadowsocks:
                guard let destination = nativeDestination else { return nil }
                return NativeShadowsocksRelayConnector(target: target, destination: destination)
            case .vless:
                if target.parameters["network"]?.lowercased() == "ws" {
                    return NativeVLESSWebSocketRelayConnector(target: target)
                }
                return NativeVLESSRelayConnector(target: target)
            case .trojan: return NativeTrojanRelayConnector(target: target)
            case .hysteria2: return nil
            }
        }()
        let nativeInitialPayload: Data? = {
            guard let target = nativeTarget else { return nil }
            switch NativeConnectorRegistry.kind(for: target) {
            case .vless:
                guard let destination = nativeDestination else { return nil }
                return try? NativeVLESSOutboundConnector(target: target).handshake(for: destination)
            case .trojan:
                guard let destination = nativeDestination else { return nil }
                return try? NativeTrojanOutboundConnector(target: target).handshake(for: destination)
            default:
                return nil
            }
        }()
        let nativeUsesSOCKS5: Bool = if nativeConnector != nil,
                                         let target = nativeTarget {
            NativeConnectorRegistry.kind(for: target) == .socks5
        } else {
            // A legacy Mihomo route speaks SOCKS5; an unsupported native
            // target must not be mistaken for one and is handled fail-closed.
            routePlan?.proxy != nil
        }
        let capability: NativeConnectorCapability = if nativeConnector != nil {
            .native
        } else if routePlan?.proxy != nil {
            .legacyFallback
        } else {
            .unsupported
        }
        let nativeDecision = currentState.nativeMode
            ? Self.normalizedNativeDecision(
                outcome.decision,
                target: nativeTarget,
                transportProtocol: .tcp
            )
            : outcome.decision
        return TCPFlowInterceptionPlan(
            decision: nativeDecision,
            destination: routePlan?.destinations.original ?? nativeDestination,
            mihomoDestination: routePlan?.destinations.mihomo,
            nativeTarget: nativeTarget,
            proxy: routePlan?.proxy,
            nativeConnector: nativeConnector,
            nativeInitialPayload: nativeInitialPayload,
            nativeUsesSOCKS5Handshake: nativeUsesSOCKS5,
            connectorCapability: capability,
            unavailableFallback: unavailableFallbackRequested(
                by: nativeDecision,
                rulesByIdentifier: currentState.rulesByIdentifier
            ),
            activity: outcome.activity
        )
    }

    func decideTCPFlow(_ flow: NEAppProxyTCPFlow) -> FlowTrafficDecision {
        planTCPFlow(flow).decision
    }

    func isTrustedMClashComponent(_ flow: NEAppProxyFlow) -> Bool {
        if trustedComponentPolicy.contains(
            metadataSigningIdentifier: flow.metaData.sourceAppSigningIdentifier
        ) {
            return true
        }
        guard let auditToken = flow.metaData.sourceAppAuditToken else { return false }
        return trustedComponentPolicy.contains(
            identityCache.resolve(
                sourceAppAuditToken: auditToken,
                using: identityResolver
            )
        )
    }

    /// Reuses application identity matching for a DNS proxy flow. The remote
    /// endpoint is the resolver rather than the queried hostname, so this is
    /// intentionally used only to select an application-scoped Profile route;
    /// unmatched and destination-only rules remain on the default DNS route.
    func decideDNSFlow(
        _ flow: NEAppProxyFlow,
        destination: SOCKS5Endpoint,
        transportProtocol: TransportProtocol
    ) -> FlowTrafficDecision {
        let host = destination.address.ipAddress?.presentation
            ?? destination.address.domain
            ?? ""
        var dnsState = snapshotState()
        dnsState.preparedConfiguration = dnsState.dnsPreparedConfiguration
        dnsState.rulesByIdentifier = dnsState.dnsRulesByIdentifier
        return decide(
            flow: flow,
            endpoint: FlowRemoteEndpoint(
                host: host,
                port: String(destination.port)
            ),
            transportProtocol: transportProtocol,
            state: dnsState,
            remoteHostname: destination.address.domain
        ).decision
    }

    @available(macOS 15.0, *)
    func planUDPFlow(
        _ flow: NEAppProxyUDPFlow,
        initialRemoteEndpoint: Network.NWEndpoint,
        parentFlowIdentifier: UUID? = nil
    ) -> UDPFlowInterceptionPlan {
        guard let endpoint = Self.endpoint(initialRemoteEndpoint) else {
            return UDPFlowInterceptionPlan(
                decision: failOpen(.unsupportedRemoteEndpoint),
                initialDestination: nil,
                mihomoDestination: nil,
                nativeTarget: nil,
                proxy: nil,
                unavailableFallback: .direct,
                activity: fallbackActivity(
                    flow: flow,
                    endpoint: nil,
                    transportProtocol: .udp,
                    failure: .unsupportedRemoteEndpoint
                ),
                parentFlowIdentifier: parentFlowIdentifier
            )
        }
        return planUDPFlow(
            flow: flow,
            endpoint: endpoint,
            state: snapshotState(),
            parentFlowIdentifier: parentFlowIdentifier
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
        initialRemoteEndpoint: NetworkExtension.__NWEndpoint,
        parentFlowIdentifier: UUID? = nil
    ) -> UDPFlowInterceptionPlan {
        guard let endpoint = Self.legacyEndpoint(initialRemoteEndpoint) else {
            return UDPFlowInterceptionPlan(
                decision: failOpen(.unsupportedRemoteEndpoint),
                initialDestination: nil,
                mihomoDestination: nil,
                nativeTarget: nil,
                proxy: nil,
                unavailableFallback: .direct,
                activity: fallbackActivity(
                    flow: flow,
                    endpoint: nil,
                    transportProtocol: .udp,
                    failure: .unsupportedRemoteEndpoint
                ),
                parentFlowIdentifier: parentFlowIdentifier
            )
        }
        return planUDPFlow(
            flow: flow,
            endpoint: endpoint,
            state: snapshotState(),
            parentFlowIdentifier: parentFlowIdentifier
        )
    }

    /// Re-evaluates one destination of an already-owned UDP flow. A UDP socket
    /// may send datagrams to several endpoints, so the initial flow decision is
    /// not a safe substitute for a per-destination rule decision.
    func planUDPDatagram(
        _ flow: NEAppProxyUDPFlow,
        destination: SOCKS5Endpoint,
        parentFlowIdentifier: UUID
    ) -> UDPFlowInterceptionPlan {
        let endpoint = FlowRemoteEndpoint(
            host: destination.address.ipAddress?.presentation
                ?? destination.address.domain
                ?? "",
            port: destination.port
        )
        return planUDPFlow(
            flow: flow,
            endpoint: endpoint,
            state: snapshotState(),
            parentFlowIdentifier: parentFlowIdentifier,
            // An NE UDP flow's remoteHostname describes its initial target and
            // must not leak into later per-datagram destination decisions.
            remoteHostname: ""
        )
    }

    func currentRevision() -> UInt64 {
        snapshotState().revision
    }

    /// Returns the exact capture identity used to scope DNS attribution.
    /// Signing identity is intentionally taken from kernel metadata and is
    /// never inferred from a mutable process path.
    func dnsAssociationContext(for flow: NEAppProxyFlow) -> (source: String, revision: UInt64, generation: UUID)? {
        let source = flow.metaData.sourceAppSigningIdentifier
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.isEmpty else { return nil }
        let state = snapshotState()
        return (source, state.revision, state.generation)
    }

    func dnsAttributedHostname(
        endpointHost: String,
        suppliedHostname: String?,
        sourceIdentity: String
    ) -> String? {
        let currentState = snapshotState()
        return dnsAttributedHostname(
            endpointHost: endpointHost,
            suppliedHostname: suppliedHostname,
            sourceIdentity: sourceIdentity,
            revision: currentState.revision,
            generation: currentState.generation
        )
    }

    private func dnsAttributedHostname(
        endpointHost: String,
        suppliedHostname: String?,
        sourceIdentity: String,
        revision: UInt64,
        generation: UUID
    ) -> String? {
        let supplied = suppliedHostname?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let suppliedIsLiteralIP = supplied.flatMap { try? IPAddress($0) } != nil
        guard let address = try? IPAddress(endpointHost),
              supplied == nil || supplied?.isEmpty == true || suppliedIsLiteralIP,
              !sourceIdentity.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return dnsAssociations.hostname(
            for: address,
            sourceIdentity: sourceIdentity,
            configurationRevision: revision,
            generation: generation
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
            preparedConfiguration: currentState.preparedConfiguration,
            context: .failOpen(failure),
            captureEnabled: currentState.captureEnabled,
            mihomoAvailable: false
        )
    }

    private func decide(
        flow: NEAppProxyFlow,
        endpoint: FlowRemoteEndpoint,
        transportProtocol: TransportProtocol,
        state currentState: State,
        remoteHostname: String? = nil,
        activityFlowIdentifier: UUID? = nil,
        parentFlowIdentifier: UUID? = nil
    ) -> FlowDecisionOutcome {
        let metadata = flow.metaData
        let applicationMetadata = FlowApplicationMetadata(
            sourceAppAuditToken: metadata.sourceAppAuditToken,
            sourceAppUniqueIdentifier: metadata.sourceAppUniqueIdentifier,
            sourceAppSigningIdentifier: metadata.sourceAppSigningIdentifier
        )
        let identityResolution: ProcessIdentityResolution
        if let auditTokenData = applicationMetadata.sourceAppAuditToken {
            identityResolution = identityCache.resolve(
                sourceAppAuditToken: auditTokenData,
                using: identityResolver
            )
        } else {
            identityResolution = .unavailable(.invalidAuditTokenLength(expected: 32, actual: 0))
        }
        let isTrustedMClashComponent = trustedComponentPolicy.contains(identityResolution)
            || trustedComponentPolicy.contains(
                metadataSigningIdentifier: applicationMetadata.sourceAppSigningIdentifier
            )
        let suppliedHostname = remoteHostname ?? flow.remoteHostname
        let associatedHostname = dnsAttributedHostname(
            endpointHost: endpoint.host,
            suppliedHostname: suppliedHostname,
            sourceIdentity: applicationMetadata.sourceAppSigningIdentifier,
            revision: currentState.revision,
            generation: currentState.generation
        )
        let context = contextBuilder.resolve(
            endpoint: endpoint,
            remoteHostname: associatedHostname ?? suppliedHostname,
            metadata: applicationMetadata,
            identityResolution: identityResolution,
            transportProtocol: transportProtocol,
            isTrustedMClashComponent: isTrustedMClashComponent
        )
        let preliminaryDecision = decisionAdapter.decide(
            preparedConfiguration: currentState.preparedConfiguration,
            context: context,
            captureEnabled: currentState.captureEnabled,
            mihomoAvailable: !currentState.mihomoSOCKSConfigurations.isEmpty
        )
        let decision = MihomoRouteAvailabilityPolicy.resolve(
            preliminaryDecision,
            availableRoutes: currentState.availableMihomoRoutes,
            rulesByIdentifier: currentState.rulesByIdentifier
        )
        return FlowDecisionOutcome(
            decision: decision,
            destinationHostname: context.context?.destination.hostname,
            activity: makeActivity(
                flow: flow,
                endpoint: endpoint,
                transportProtocol: transportProtocol,
                context: context,
                identityResolution: identityResolution,
                decision: decision,
                state: currentState,
                flowIdentifier: activityFlowIdentifier,
                parentFlowIdentifier: parentFlowIdentifier
            )
        )
    }

    /// Native mode has no Mihomo rescue path. An outbound rule without a
    /// concrete supported target is converted to an explicit reject while
    /// retaining the rule evidence and unavailable reason for diagnostics.
    static func normalizedNativeDecision(
        _ decision: FlowTrafficDecision,
        target: OutboundNodeTarget?,
        transportProtocol: TransportProtocol
    ) -> FlowTrafficDecision {
        guard case .outbound = decision.disposition,
              let target,
              (transportProtocol == .tcp
                ? NativeConnectorRegistry.supportsNativeTCP(target)
                : NativeConnectorRegistry.supportsNativeUDP(target)) else {
            guard case .outbound = decision.disposition else { return decision }
            let fallback: UnavailableFallback = .reject
            let cause: RuleDecisionCause
            switch decision.reason {
            case let .rule(value), let .outboundUnavailable(rule: value, fallback: _): cause = value
            default: cause = .defaultDirect
            }
            return FlowTrafficDecision(
                disposition: .reject,
                reason: .outboundUnavailable(rule: cause, fallback: fallback),
                ruleEvidence: decision.ruleEvidence
            )
        }
        return decision
    }

    private func planUDPFlow(
        flow: NEAppProxyUDPFlow,
        endpoint: FlowRemoteEndpoint,
        state currentState: State,
        parentFlowIdentifier: UUID? = nil,
        remoteHostname: String? = nil
    ) -> UDPFlowInterceptionPlan {
        let outcome = decide(
            flow: flow,
            endpoint: endpoint,
            transportProtocol: .udp,
            state: currentState,
            remoteHostname: remoteHostname,
            parentFlowIdentifier: parentFlowIdentifier
        )
        let routePlan: ProviderSOCKSFlowPlan?
        let nativeRoute: OutboundRoute? = if case let .outbound(route) = outcome.decision.disposition { route } else { nil }
        let nativeDecision = currentState.nativeMode
            ? Self.normalizedNativeDecision(
                outcome.decision,
                target: nativeRoute.flatMap { currentState.outboundNodeTargets?.target(for: $0) },
                transportProtocol: .udp
            )
            : outcome.decision
        if currentState.nativeMode {
            routePlan = nil
        } else if case .reject = nativeDecision.disposition,
           let destinations = try? ProviderSOCKSConfiguration.destinations(
               for: endpoint,
               preferredHostname: outcome.destinationHostname
           ) {
            routePlan = ProviderSOCKSFlowPlan(
                destinations: destinations,
                proxy: nil
            )
        } else {
            routePlan = try? ProviderSOCKSConfiguration.flowPlan(
                for: nativeDecision,
                endpoint: endpoint,
                preferredHostname: outcome.destinationHostname,
                routeCatalog: currentState.mihomoSOCKSConfigurations
            )
        }
        // Native SOCKS5 is a complete UDP association endpoint. Keep this
        // target independent from the loopback Mihomo route catalog; the
        // legacy catalog remains available as a fallback below.
        let nativeTarget: OutboundNodeTarget? = {
            guard currentState.nativeMode,
                  case let .outbound(route) = nativeDecision.disposition,
                  let target = currentState.outboundNodeTargets?.target(for: route),
                  NativeConnectorRegistry.supportsNativeUDP(target) else { return nil }
            return target
        }()
        let nativeDestination = try? ProviderSOCKSConfiguration.destination(for: endpoint)
        return UDPFlowInterceptionPlan(
            decision: nativeDecision,
            initialDestination: routePlan?.destinations.original ?? nativeDestination,
            mihomoDestination: routePlan?.destinations.mihomo,
            nativeTarget: nativeTarget,
            proxy: routePlan?.proxy,
            unavailableFallback: unavailableFallbackRequested(
                by: nativeDecision,
                rulesByIdentifier: currentState.rulesByIdentifier
            ),
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
        state: State,
        flowIdentifier: UUID? = nil,
        parentFlowIdentifier: UUID? = nil
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
            rulesByIdentifier: state.rulesByIdentifier
        )
        let terminal: Bool = switch decision.disposition {
        case .outbound: false
        case .direct, .reject, .failOpen: true
        }

        return AppRoutingActivity(
            flowIdentifier: flowIdentifier ?? UUID(),
            parentFlowIdentifier: parentFlowIdentifier,
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
        rulesByIdentifier: [String: CaptureRule]
    ) -> CaptureAction {
        let cause: RuleDecisionCause?
        switch decision.reason {
        case let .rule(value):
            cause = value
        case let .outboundUnavailable(rule, _):
            cause = rule
        case .captureDisabled, .configurationUnavailable, .contextUnavailable:
            cause = nil
        }
        if case let .matchedRule(identifier) = cause,
           let rule = rulesByIdentifier[identifier] {
            return rule.action
        }
        return switch decision.disposition {
        case .reject: .reject
        case let .outbound(route): .outbound(route)
        case .direct, .failOpen: .direct
        }
    }

    private func unavailableFallbackRequested(
        by decision: FlowTrafficDecision,
        rulesByIdentifier: [String: CaptureRule]
    ) -> UnavailableFallback {
        let cause: RuleDecisionCause?
        switch decision.reason {
        case let .rule(value):
            cause = value
        case let .outboundUnavailable(rule, fallback):
            if case .matchedRule = rule {
                return fallback
            }
            cause = rule
        case .captureDisabled, .configurationUnavailable, .contextUnavailable:
            cause = nil
        }
        if case let .matchedRule(identifier) = cause,
           let rule = rulesByIdentifier[identifier] {
            return rule.unavailableFallback
        }
        return .direct
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
    let destinationHostname: String?
    let activity: AppRoutingActivity
}

struct TCPFlowInterceptionPlan: Sendable {
    let decision: FlowTrafficDecision
    /// Original macOS endpoint, retained for Direct and unavailable fallback.
    let destination: SOCKS5Endpoint?
    /// Hostname-preserving SOCKS target used only for Mihomo relay.
    let mihomoDestination: SOCKS5Endpoint?
    /// Node-only target used by native connectors, independent of Mihomo.
    let nativeTarget: OutboundNodeTarget?
    let proxy: ProviderSOCKSConfiguration?
    let nativeConnector: (any OutboundConnector)?
    let nativeInitialPayload: Data?
    let nativeUsesSOCKS5Handshake: Bool
    let connectorCapability: NativeConnectorCapability
    let unavailableFallback: UnavailableFallback
    let activity: AppRoutingActivity
}

struct UDPFlowInterceptionPlan: Sendable {
    let decision: FlowTrafficDecision
    /// Original datagram endpoint, retained as the conversation key and for Direct.
    let initialDestination: SOCKS5Endpoint?
    /// Hostname-preserving SOCKS target used only for Mihomo relay.
    let mihomoDestination: SOCKS5Endpoint?
    /// Node-only native target. Present only for native SOCKS5 UDP routes;
    /// nil means the route must use the compatibility listener path.
    let nativeTarget: OutboundNodeTarget?
    let proxy: ProviderSOCKSConfiguration?
    let unavailableFallback: UnavailableFallback
    let activity: AppRoutingActivity
    let parentFlowIdentifier: UUID?

    init(
        decision: FlowTrafficDecision,
        initialDestination: SOCKS5Endpoint?,
        mihomoDestination: SOCKS5Endpoint?,
        nativeTarget: OutboundNodeTarget? = nil,
        proxy: ProviderSOCKSConfiguration?,
        unavailableFallback: UnavailableFallback,
        activity: AppRoutingActivity,
        parentFlowIdentifier: UUID? = nil
    ) {
        self.decision = decision
        self.initialDestination = initialDestination
        self.mihomoDestination = mihomoDestination
        self.nativeTarget = nativeTarget
        self.proxy = proxy
        self.unavailableFallback = unavailableFallback
        self.activity = activity
        self.parentFlowIdentifier = parentFlowIdentifier ?? activity.parentFlowIdentifier
    }
}
