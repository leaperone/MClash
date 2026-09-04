import Foundation
@preconcurrency import Network
import MClashNetworkShared

/// Capabilities exposed by a runtime controller. These values describe the
/// implementation boundary, rather than claiming that every protocol is
/// enabled for every profile.
enum NativeRuntimeCapability: String, CaseIterable, Hashable, Sendable {
    case nativeRuntime
    case nativeRouting
    case nativeDNS
    case legacyCore
    case legacyController
}

struct NativeRuntimeDiagnostics: Equatable, Sendable {
    let state: CoreRunState
    let capabilities: Set<NativeRuntimeCapability>
    let backend: String
    let controlPlaneAvailable: Bool
    let lastError: String?
    let startedAt: Date?
    /// Whether this engine has an MClash-owned policy snapshot attached.
    let hasCompiledRuntimePlan: Bool
    /// Revision of the attached policy snapshot, when one is present.
    let workspaceRevision: Int?
    /// Listener counts come from the MClash registry, never from Mihomo.
    let listenerCount: Int
    let enabledListenerCount: Int
    /// Number of enabled socket entrances (HTTP/SOCKS5). App Routing and
    /// TUN are capability entries, not app-owned TCP sockets.
    let enabledSocketListenerCount: Int
    /// Validation failures are surfaced independently of lifecycle failures.
    let sessionValidationError: String?
    /// Lifecycle state of each MClash-owned entrance. Native listeners are
    /// represented by safe in-process handles; this does not imply that a
    /// production socket was bound by the engine.
    let listenerStates: [UUID: NativeListenerLifecycleState]
    /// Capability matrix for every catalog entry, including native and
    /// compatibility paths. This is the authoritative connector-neutral
    /// report exposed to diagnostics clients.
    let connectorCapabilities: [OutboundConnectorCapabilityMatrixEntry]
    /// Connector capabilities discovered from the attached node catalog.
    /// Unknown protocols are reported here instead of silently falling back
    /// to a direct connection.
    let unsupportedConnectors: [NativeRuntimeConnectorDiagnostic]
    /// Native GEO database capability is reported separately from connector
    /// support so a policy author can distinguish "no match" from "database
    /// unavailable" without inspecting implementation logs.
    let geoDatabaseStatus: NativeGeoDatabaseStatus
}

/// A connector-neutral explanation for a node that the native data plane
/// cannot currently use.  This is deliberately a value type so the UI and
/// CLI can present an actionable diagnostic without knowing Mihomo's model.
struct NativeRuntimeConnectorDiagnostic: Equatable, Sendable {
    let route: OutboundRoute
    let protocolName: String
    let reason: String
}

/// The result of evaluating one intercepted flow against MClash's policy.
/// `decision` remains authoritative; `route` and `target` are populated only
/// for an outbound decision whose group can be resolved in the node catalog.
/// A missing/unsupported target is explicit and never becomes `.direct`.
struct NativeRuntimeRouteEvaluation: Equatable, Sendable {
    let decision: NativeRouteDecision
    let route: OutboundRoute?
    let target: OutboundNodeTarget?
    let connectorDiagnostic: NativeRuntimeConnectorDiagnostic?
}

enum NativeListenerLifecycleState: Equatable, Sendable {
    case stopped
    case starting
    case running
    case failed(String)
}

/// A handle for an entrance owned and bound by the app-process runtime.
struct NativeListenerHandle: Equatable, Sendable {
    let id: UUID
    let name: String
    let kind: MClashListenerKind
    var endpoint: String?
    let route: MClashListenerRoute
    var socketBound: Bool
    var state: NativeListenerLifecycleState

    init(spec: MClashListenerSpec, state: NativeListenerLifecycleState = .stopped) {
        id = spec.id
        name = spec.name
        kind = spec.kind
        endpoint = spec.endpoint
        route = spec.route
        socketBound = false
        self.state = state
    }
}

/// The complete native session policy.  A native engine must receive this
/// state before it can bind listeners or route traffic; it never reconstructs
/// policy from a rendered Mihomo YAML document.
struct NativeRuntimeSessionState: Equatable, Sendable {
    let plan: CompiledRuntimePlan
    let listeners: MClashListenerRegistry

    init(plan: CompiledRuntimePlan, listeners: MClashListenerRegistry) throws {
        do {
            try plan.validate()
        } catch let error as CompiledRuntimePlanValidationError {
            throw NativeRuntimeSessionValidationError.invalidPlan(error)
        }
        if let externalRuleSet = plan.ruleSets.first(where: {
            NativeRuleSetSupport.assess($0) == .externalRequiresLoader
        }) {
            throw NativeRuntimeSessionValidationError
                .externalRuleSetRequiresLoader(externalRuleSet.id)
        }
        for ruleSet in plan.ruleSets
        where NativeRuleSetSupport.assess(ruleSet) == .localText {
            do {
                _ = try NativeRuleSetFileLoader.load(ruleSet)
            } catch {
                throw NativeRuntimeSessionValidationError
                    .ruleSetFileLoadFailed(ruleSet.id, error.localizedDescription)
            }
        }
        do {
            try MClashListenerRegistry.validate(listeners.listeners)
        } catch let error as MClashListenerRegistryError {
            throw NativeRuntimeSessionValidationError.invalidListeners(error)
        }
        self.plan = plan
        self.listeners = listeners
    }
}

enum NativeRuntimeSessionValidationError: Error, Equatable, Sendable {
    case invalidPlan(CompiledRuntimePlanValidationError)
    case externalRuleSetRequiresLoader(RuleSetID)
    case ruleSetFileLoadFailed(RuleSetID, String)
    case invalidListeners(MClashListenerRegistryError)
}

extension NativeRuntimeSessionValidationError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case let .invalidPlan(error):
            "Native runtime policy plan is invalid: \(error.localizedDescription)"
        case let .externalRuleSetRequiresLoader(id):
            "Native runtime rule set \(id.rawValue.uuidString.lowercased()) requires an explicit native loader; no policy was activated."
        case let .ruleSetFileLoadFailed(id, reason):
            "Native runtime could not load rule set \(id.rawValue.uuidString.lowercased()): \(reason)"
        case let .invalidListeners(error):
            "Native runtime listener registry is invalid: \(error.localizedDescription)"
        }
    }
}

extension CoreRunState {
    var isRunning: Bool {
        if case .running = self { return true }
        return false
    }

    var session: CoreSession? {
        if case let .running(value) = self { return value }
        return nil
    }
}

/// In-process runtime lifecycle for the native control plane.
///
/// The app process owns its HTTP/SOCKS5 entrances; Mihomo is never started.
final actor NativeRuntimeEngine: ProfileRuntimeSession {
    nonisolated let events: AsyncStream<CoreEvent>
    nonisolated let flowObservations: NativeFlowObservationStore
    nonisolated var nativeFlowObservations: NativeFlowObservationStore? { flowObservations }
    nonisolated let runtimeCapabilities: Set<NativeRuntimeCapability> = [
        .nativeRuntime,
        .nativeRouting,
        .nativeDNS
    ]
    nonisolated let metadata = ProfileRuntimeSessionMetadata(
        backend: .native,
        capabilities: [
            .nativeRuntime,
            .nativeRouting,
            .nativeDNS
        ]
    )

    private let continuation: AsyncStream<CoreEvent>.Continuation
    private var currentState: CoreRunState = .stopped
    private var lastError: String?
    private var startedAt: Date?
    private var sessionState: NativeRuntimeSessionState?
    private var sessionValidationError: String?
    private var listenerHandles: [UUID: NativeListenerHandle] = [:]
    private var outboundNodeTargets: OutboundNodeTargetCatalog?
    private var inboundListeners: [UUID: MClashInboundListener] = [:]
    private var listenerGeneration: UInt64 = 0
    private let geoProvider: (any NativeGeoDatabaseProvider)?
    private let geoMatcher: NativeGeoMatcher?

    init() {
        let pair = AsyncStream<CoreEvent>.makeStream(
            of: CoreEvent.self,
            bufferingPolicy: .bufferingNewest(500)
        )
        events = pair.stream
        continuation = pair.continuation
        flowObservations = NativeFlowObservationStore()
        sessionState = nil
        sessionValidationError = nil
        outboundNodeTargets = nil
        geoProvider = Self.loadBundledGeoIPProvider()
        if let provider = geoProvider {
            geoMatcher = { kind, value, context in provider.matches(kind: kind, value: value, context: context) }
        } else { geoMatcher = nil }
    }

    /// Creates an engine with a validated, MClash-owned policy snapshot.
    /// This initializer is intentionally separate from the no-argument
    /// compatibility initializer used by AppModel's opt-in switch.
    init(
        plan: CompiledRuntimePlan,
        listeners: MClashListenerRegistry,
        outboundNodeTargets: OutboundNodeTargetCatalog? = nil,
        geoProvider: (any NativeGeoDatabaseProvider)? = nil
    ) throws {
        let pair = AsyncStream<CoreEvent>.makeStream(
            of: CoreEvent.self,
            bufferingPolicy: .bufferingNewest(500)
        )
        events = pair.stream
        continuation = pair.continuation
        flowObservations = NativeFlowObservationStore()
        sessionState = try NativeRuntimeSessionState(plan: plan, listeners: listeners)
        sessionValidationError = nil
        listenerHandles = Self.makeListenerHandles(for: listeners)
        self.outboundNodeTargets = outboundNodeTargets
            ?? Self.makeOutboundNodeTargetCatalog(from: plan)
        self.geoProvider = geoProvider ?? Self.loadBundledGeoIPProvider()
        if let provider = self.geoProvider {
            self.geoMatcher = { kind, value, context in provider.matches(kind: kind, value: value, context: context) }
        } else { self.geoMatcher = nil }
    }

    func configure(plan: CompiledRuntimePlan, listeners: MClashListenerRegistry) async throws {
        let state: NativeRuntimeSessionState
        do {
            state = try NativeRuntimeSessionState(plan: plan, listeners: listeners)
        } catch {
            sessionValidationError = error.localizedDescription
            throw error
        }
        var catalog = Self.makeOutboundNodeTargetCatalog(from: plan)
        if let unresolvedCatalog = catalog,
           let bootstrap = Self.nativeDNSBootstrap(from: plan) {
            catalog = await NativeHostnameResolver(
                bootstrap: bootstrap
            ).resolving(unresolvedCatalog)
        }
        if currentState.isRunning,
           Self.socketShape(of: sessionState?.listeners)
            == Self.socketShape(of: listeners) {
            let route = makeRouteResolver(plan: plan, catalog: catalog)
            let connector = NativeAppCatalogConnector(catalog: catalog)
            for listener in inboundListeners.values {
                listener.reconfigure(route: route, connector: connector)
            }
            let previousHandles = listenerHandles
            sessionState = state
            listenerHandles = Self.makeListenerHandles(for: listeners)
            for id in listenerHandles.keys {
                guard var handle = listenerHandles[id],
                      let previous = previousHandles[id] else { continue }
                handle.state = previous.state
                handle.socketBound = previous.socketBound
                handle.endpoint = previous.endpoint
                listenerHandles[id] = handle
            }
            outboundNodeTargets = catalog
            sessionValidationError = nil
            lastError = nil
            continuation.yield(.log(CoreLogLine(
                stream: .supervisor,
                message: "Native runtime policy reloaded without rebinding listener sockets."
            )))
            return
        }
        if currentState.isRunning,
           Self.socketShapesOverlap(sessionState?.listeners, listeners) {
            throw CoreSupervisorError.configurationInvalid(
                "Native listener endpoints changed in place; reconnect to apply the new socket layout."
            )
        }
        // Construct every socket object before replacing the current session;
        // invalid reloads leave the last-known-good listeners untouched.
        let replacements = try makeInboundListeners(registry: listeners, plan: plan, catalog: catalog)
        let oldListeners = inboundListeners
        listenerGeneration &+= 1
        sessionState = state
        listenerHandles = Self.makeListenerHandles(for: listeners)
        outboundNodeTargets = catalog
        inboundListeners = replacements
        oldListeners.values.forEach { $0.stop() }
        if currentState.isRunning { beginListeners() }
        sessionValidationError = nil
        lastError = nil
        continuation.yield(.log(CoreLogLine(
            stream: .supervisor,
            message: "Native runtime policy attached (workspace revision \(plan.workspaceRevision), \(listeners.listeners.count) listener(s))."
        )))
    }

    /// Attach the connector-neutral node material used by the native data
    /// plane. This is intentionally separate from `configure` so the existing
    /// NativeRuntimeController seam stays source-compatible with the legacy
    /// Mihomo adapter during migration.
    func configureOutboundTargets(_ catalog: OutboundNodeTargetCatalog?) async {
        guard let state = sessionState else {
            outboundNodeTargets = catalog
            return
        }
        if currentState.isRunning {
            let route = makeRouteResolver(plan: state.plan, catalog: catalog)
            let connector = NativeAppCatalogConnector(catalog: catalog)
            for listener in inboundListeners.values {
                listener.reconfigure(route: route, connector: connector)
            }
            outboundNodeTargets = catalog
            lastError = nil
            return
        }
        do {
            let replacements = try makeInboundListeners(
                registry: state.listeners,
                plan: state.plan,
                catalog: catalog
            )
            listenerGeneration &+= 1
            inboundListeners.values.forEach { $0.stop() }
            inboundListeners = replacements
            outboundNodeTargets = catalog
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Evaluate one flow using MClash's rule projection and resolve its
    /// selected group to node material. No socket is opened here; this pure
    /// decision hook is consumed by the listener/relay layer and is easy to
    /// exercise in isolation.
    func evaluate(_ context: FlowContext) -> NativeRuntimeRouteEvaluation {
        guard let sessionState else {
            return NativeRuntimeRouteEvaluation(
                decision: NativeRouteDecision(action: .direct),
                route: nil,
                target: nil,
                connectorDiagnostic: NativeRuntimeConnectorDiagnostic(
                    route: .profileRules,
                    protocolName: "",
                    reason: "Native runtime has no compiled policy session."
                )
            )
        }

        let decision = NativeRuleEngineProjection(plan: sessionState.plan, geoMatcher: geoMatcher).evaluate(context)
        guard case let .outbound(groupID) = decision.action,
              let group = sessionState.plan.proxyGroups.first(where: { $0.id == groupID }) else {
            return NativeRuntimeRouteEvaluation(decision: decision, route: nil, target: nil, connectorDiagnostic: nil)
        }

        let route = OutboundRoute.group(group.name)
        guard let target = outboundNodeTargets?.target(for: route) else {
            let diagnostic = NativeRuntimeConnectorDiagnostic(
                route: route,
                protocolName: "",
                reason: "Proxy group \(group.name) has no native node target."
            )
            return NativeRuntimeRouteEvaluation(decision: decision, route: route, target: nil, connectorDiagnostic: diagnostic)
        }

        if let reason = Self.unsupportedConnectorReason(for: target) {
            let diagnostic = NativeRuntimeConnectorDiagnostic(
                route: route,
                protocolName: target.protocolName,
                reason: reason
            )
            return NativeRuntimeRouteEvaluation(decision: decision, route: route, target: target, connectorDiagnostic: diagnostic)
        }
        return NativeRuntimeRouteEvaluation(decision: decision, route: route, target: target, connectorDiagnostic: nil)
    }

    /// Labelled form for call sites that handle several destination kinds.
    func evaluate(destination context: FlowContext) -> NativeRuntimeRouteEvaluation {
        evaluate(context)
    }

    func nativeSessionState() -> NativeRuntimeSessionState? { sessionState }

    func nativeGeoDatabaseStatus() -> NativeGeoDatabaseStatus {
        geoProvider?.status ?? .unavailable
    }

    func state() async -> CoreRunState { currentState }

    func diagnostics() async -> NativeRuntimeDiagnostics {
        NativeRuntimeDiagnostics(
            state: currentState,
            capabilities: runtimeCapabilities,
            backend: "native",
            // The lifecycle engine deliberately has no HTTP controller.
            controlPlaneAvailable: false,
            lastError: lastError,
            startedAt: startedAt,
            hasCompiledRuntimePlan: sessionState != nil,
            workspaceRevision: sessionState?.plan.workspaceRevision,
            listenerCount: sessionState?.listeners.listeners.count ?? 0,
            enabledListenerCount: sessionState?.listeners.enabledListeners.count ?? 0,
            enabledSocketListenerCount: sessionState?.listeners.enabledListeners
                .filter { $0.kind.requiresSocketEndpoint }.count ?? 0,
            sessionValidationError: sessionValidationError,
            listenerStates: listenerHandles.mapValues(\.state),
            connectorCapabilities: Self.connectorCapabilityMatrix(in: outboundNodeTargets),
            unsupportedConnectors: Self.unsupportedConnectors(in: outboundNodeTargets),
            geoDatabaseStatus: geoProvider?.status ?? .unavailable
        )
    }

    /// Returns a stable snapshot of the native listener handles. Handles are
    /// sorted by registry order so callers never depend on dictionary order.
    func nativeListenerHandles() -> [NativeListenerHandle] {
        listenerHandles.values.sorted { $0.id.uuidString < $1.id.uuidString }
    }

    func start(_ configuration: CoreLaunchConfiguration) async throws {
        guard !currentState.isRunning else {
            throw CoreSupervisorError.alreadyRunning
        }
        try await validateConfiguration(configuration)
        if inboundListeners.isEmpty, let state = sessionState {
            inboundListeners = try makeInboundListeners(
                registry: state.listeners,
                plan: state.plan,
                catalog: outboundNodeTargets
            )
            listenerGeneration &+= 1
        }
        transition(to: .starting)
        beginListeners()
        let now = Date()
        startedAt = now
        lastError = nil
        transition(to: .running(CoreSession(
            endpoint: configuration.controllerEndpoint,
            secret: configuration.secret,
            version: "native",
            startedAt: now
        )))
        emitLog("Native runtime started; no Mihomo process was launched.")
    }

    @discardableResult
    func stop() async -> Bool {
        stopListeners()
        // Close any observation that did not receive a transport callback
        // while listeners were being cancelled. This keeps Traffic/Flow
        // Ledger consistent with the runtime lifecycle.
        _ = await flowObservations.finishActive()
        startedAt = nil
        lastError = nil
        transition(to: .stopped)
        return true
    }

    func validate(_ configuration: CoreLaunchConfiguration) async throws {
        transition(to: .validating)
        do {
            try await validateConfiguration(configuration)
            transition(to: .stopped)
            emitLog("Native runtime configuration validated.")
        } catch is CancellationError {
            transition(to: .stopped)
            throw CancellationError()
        } catch {
            let message = error.localizedDescription
            lastError = message
            transition(to: .failed(message))
            throw error
        }
    }

    func validateWithoutStateChanges(_ configuration: CoreLaunchConfiguration) async throws {
        try await validateConfiguration(configuration)
    }

    nonisolated func setProcessLogForwardingEnabled(_ enabled: Bool) {
        // Native runtime has no child process pipes. Kept as a no-op to make
        // the controller safe to substitute at the existing AppModel seam.
    }

    private func validateConfiguration(_ configuration: CoreLaunchConfiguration) async throws {
        try Task.checkCancellation()
        guard !configuration.secret.isEmpty else {
            throw CoreSupervisorError.configurationInvalid("The native runtime secret cannot be empty.")
        }
        guard configuration.controllerPort != 0 else {
            throw CoreSupervisorError.configurationInvalid("The native runtime controller port is invalid.")
        }
        var isDirectory: ObjCBool = false
        if !FileManager.default.fileExists(
            atPath: configuration.homeDirectory.path,
            isDirectory: &isDirectory
        ) {
            try FileManager.default.createDirectory(
                at: configuration.homeDirectory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            isDirectory = true
        }
        guard isDirectory.boolValue else {
            throw CoreSupervisorError.configurationInvalid("The native runtime home path is not a directory.")
        }
        // Native runtime does not consume the legacy Mihomo YAML. The URL is
        // retained in CoreLaunchConfiguration for the compatibility seam, but
        // its absence must not prevent a native session from starting.
    }

    private func transition(to state: CoreRunState) {
        currentState = state
        continuation.yield(.stateChanged(state))
    }

    private static func makeListenerHandles(
        for registry: MClashListenerRegistry
    ) -> [UUID: NativeListenerHandle] {
        Dictionary(uniqueKeysWithValues: registry.listeners.map { spec in
            (spec.id, NativeListenerHandle(spec: spec))
        })
    }

    /// The validated runtime plan is the native engine's source of truth for
    /// connector selection. Building the catalog here prevents a host-side
    /// compatibility projection from overwriting a newer group resolution.
    private static func makeOutboundNodeTargetCatalog(
        from plan: CompiledRuntimePlan
    ) -> OutboundNodeTargetCatalog? {
        func target(for groupID: ProxyGroupID) -> OutboundNodeTarget? {
            NativeProxyGroupTargetResolver.resolve(
                groupID: groupID,
                groups: plan.proxyGroups,
                nodes: plan.nodes
            ).target
        }

        let primaryGroupID = plan.globalProxyGroupID ?? plan.proxyGroups.first?.id
        var entries: [OutboundNodeTargetEntry] = []
        if let primaryGroupID, let target = target(for: primaryGroupID) {
            entries.append(.init(route: .profileRules, target: target))
            entries.append(.init(route: .global, target: target))
        }
        for group in plan.proxyGroups {
            guard let target = target(for: group.id) else { continue }
            entries.append(.init(route: .group(group.name), target: target))
        }
        guard !entries.isEmpty else { return nil }
        return try? OutboundNodeTargetCatalog(entries: entries)
    }

    private static func nativeDNSBootstrap(
        from plan: CompiledRuntimePlan
    ) -> DNSUpstreamBootstrap? {
        guard let policy = plan.dnsPolicy else { return nil }
        var seen = Set<MClashNetworkShared.IPAddress>()
        let endpoints = (policy.nameservers + policy.fallbackNameservers).compactMap {
            raw -> DNSUpstreamEndpoint? in
            guard let address = try? MClashNetworkShared.IPAddress(raw), seen.insert(address).inserted else {
                return nil
            }
            return try? DNSUpstreamEndpoint(address: address, transport: .udp)
        }
        return try? DNSUpstreamBootstrap(
            endpoints: endpoints,
            policyRules: policy.rules
        )
    }

    private func beginListeners() {
        guard let registry = sessionState?.listeners else { return }
        for spec in registry.listeners {
            guard var handle = listenerHandles[spec.id] else { continue }
            handle.state = spec.enabled && spec.kind.requiresSocketEndpoint ? .starting : .stopped
            listenerHandles[spec.id] = handle
        }
        for spec in registry.enabledListeners {
            guard let listener = inboundListeners[spec.id], var handle = listenerHandles[spec.id] else { continue }
            handle.state = .starting
            listenerHandles[spec.id] = handle
            listener.start()
        }
    }

    private func stopListeners() {
        listenerGeneration &+= 1
        inboundListeners.values.forEach { $0.stop() }
        inboundListeners.removeAll()
        for id in listenerHandles.keys {
            guard var handle = listenerHandles[id] else { continue }
            handle.state = .stopped
            handle.socketBound = false
            listenerHandles[id] = handle
        }
    }

    private func makeInboundListeners(
        registry: MClashListenerRegistry,
        plan: CompiledRuntimePlan,
        catalog: OutboundNodeTargetCatalog?
    ) throws -> [UUID: MClashInboundListener] {
        let generation = listenerGeneration &+ 1
        let route = makeRouteResolver(plan: plan, catalog: catalog)
        var result: [UUID: MClashInboundListener] = [:]
        for spec in registry.enabledListeners where spec.kind.requiresSocketEndpoint {
            guard let port = spec.port else { continue }
            let kind: MClashInboundListener.Kind = spec.kind == .http ? .httpConnect : .socks5
            let listener = try MClashInboundListener(
                kind: kind,
                bindAddress: spec.bindAddress,
                port: port,
                route: route,
                connector: NativeAppCatalogConnector(catalog: catalog),
                stateHandler: { [weak self] ready, actualPort in
                    guard let self else { return }
                    Task { await self.listenerDidChange(id: spec.id, bindAddress: spec.bindAddress, generation: generation, ready: ready, port: actualPort) }
                },
                entranceName: spec.name,
                observationHandler: { [flowObservations] observation in
                    Task { await flowObservations.receive(observation) }
                }
            )
            result[spec.id] = listener
        }
        return result
    }

    private func makeRouteResolver(
        plan: CompiledRuntimePlan,
        catalog: OutboundNodeTargetCatalog?
    ) -> @Sendable (MClashInboundDestination) -> MClashInboundRoute {
        let projection = NativeRuleEngineProjection(plan: plan, geoMatcher: geoMatcher)
        return { destination in
            guard let flowDestination = try? FlowDestination(
                hostname: destination.host,
                port: destination.port
            ) else { return .reject }
            let context = FlowContext(
                source: FlowSource(
                    processIdentifier: 0,
                    auditToken: Data(),
                    userID: 0
                ),
                destination: flowDestination,
                transportProtocol: .tcp
            )
            switch projection.evaluate(context).action {
            case .direct:
                return .direct
            case .reject:
                return .reject
            case let .outbound(groupID):
                guard let group = plan.proxyGroups.first(where: { $0.id == groupID }),
                      let target = catalog?.target(for: .group(group.name)),
                      NativeAppCatalogConnector.supports(target) else {
                    return .reject
                }
                return .proxy(OutboundRoute.group(group.name).stableSortKey)
            }
        }
    }

    private static func socketShape(
        of registry: MClashListenerRegistry?
    ) -> [UUID: String] {
        guard let registry else { return [:] }
        return Dictionary(uniqueKeysWithValues: registry.enabledListeners.compactMap {
            spec -> (UUID, String)? in
            guard spec.kind.requiresSocketEndpoint, let port = spec.port else { return nil }
            return (
                spec.id,
                "\(spec.kind.rawValue):\(spec.bindAddress):\(port)"
            )
        })
    }

    private static func loadBundledGeoIPProvider() -> (any NativeGeoDatabaseProvider)? {
        let candidates = [
            ProcessInfo.processInfo.environment["MCLASH_GEOIP_DAT_PATH"].map { URL(fileURLWithPath: $0) },
            Bundle.main.url(forResource: "GeoIP", withExtension: "dat"),
            Bundle.main.url(forResource: "GeoIP", withExtension: "dat", subdirectory: "GeoData")
        ].compactMap { $0 }
        for url in candidates {
            if let data = try? Data(contentsOf: url),
               let provider = try? NativeGeoIPDatabaseProvider(data: data) {
                return provider
            }
        }
        return nil
    }

    private static func socketShapesOverlap(
        _ current: MClashListenerRegistry?,
        _ replacement: MClashListenerRegistry
    ) -> Bool {
        let currentEndpoints = Set(
            current?.enabledListeners.compactMap(\.endpoint) ?? []
        )
        let replacementEndpoints = Set(
            replacement.enabledListeners.compactMap(\.endpoint)
        )
        return !currentEndpoints.isDisjoint(with: replacementEndpoints)
    }

    private func listenerDidChange(id: UUID, bindAddress: String, generation: UInt64, ready: Bool, port: UInt16?) {
        guard generation == listenerGeneration, var handle = listenerHandles[id] else { return }
        handle.state = ready ? .running : .failed("Native listener socket failed")
        handle.socketBound = ready
        if let port {
            let host = bindAddress.contains(":") ? "[\(bindAddress)]" : bindAddress
            handle.endpoint = "\(host):\(port)"
        }
        listenerHandles[id] = handle
        if !ready { lastError = "Native listener \(id) failed to bind." }
    }

    private func emitLog(_ message: String) {
        continuation.yield(.log(CoreLogLine(stream: .supervisor, message: message)))
    }

    private static let nativeConnectorProtocols: Set<String> = [
        "http", "socks5", "shadowsocks", "vless", "trojan", "hysteria2"
    ]

    private static func unsupportedConnectorReason(for target: OutboundNodeTarget) -> String? {
        guard nativeConnectorProtocols.contains(target.protocolName) else {
            return "Native connector for protocol \(target.protocolName) is not implemented."
        }
        if target.protocolName == "hysteria2" {
            return "Hysteria2 requires a verified QUIC session connector."
        }
        if target.protocolName == "shadowsocks",
           target.parameters["plugin"] != nil || target.parameters["plugin-opts"] != nil {
            return "Shadowsocks plugins require a dedicated native transport."
        }
        if target.protocolName == "shadowsocks",
           target.parameters.contains(where: { key, value in
               let normalized = key.trimmingCharacters(in: .whitespacesAndNewlines)
                   .lowercased().replacingOccurrences(of: "_", with: "-")
               if normalized == "udp-over-tcp-version" || normalized == "uot-version" {
                   return true
               }
               guard normalized == "udp-over-tcp" || normalized == "uot" else { return false }
               return ["true", "yes", "1", "on"].contains(
                   value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
               )
           }) {
            return "Shadowsocks UDP-over-TCP transport is not implemented by the native connector."
        }
        return nil
    }

    private static func unsupportedConnectors(
        in catalog: OutboundNodeTargetCatalog?
    ) -> [NativeRuntimeConnectorDiagnostic] {
        guard let catalog else { return [] }
        return OutboundConnectorCapabilityMatrix.entries(for: catalog).compactMap { item in
            guard let reason = item.reason else { return nil }
            return NativeRuntimeConnectorDiagnostic(
                route: item.route,
                protocolName: item.protocolName,
                reason: reason
            )
        }
    }

    private static func connectorCapabilityMatrix(
        in catalog: OutboundNodeTargetCatalog?
    ) -> [OutboundConnectorCapabilityMatrixEntry] {
        guard let catalog else { return [] }
        return OutboundConnectorCapabilityMatrix.entries(for: catalog)
    }
}
