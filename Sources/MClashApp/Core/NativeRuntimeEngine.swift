import Foundation
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

/// A safe handle for a listener owned by the native runtime.  The first
/// lifecycle slice intentionally models binding rather than opening sockets:
/// the Network Extension owns the actual listener transport. Keeping this
/// handle in the engine makes start/stop transactional and observable without
/// touching user ports during migration tests.
struct NativeListenerHandle: Equatable, Sendable {
    let id: UUID
    let name: String
    let kind: MClashListenerKind
    let endpoint: String?
    let route: MClashListenerRoute
    let socketBound: Bool
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
    case invalidListeners(MClashListenerRegistryError)
}

extension NativeRuntimeSessionValidationError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case let .invalidPlan(error):
            "Native runtime policy plan is invalid: \(error.localizedDescription)"
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
/// This first slice intentionally owns lifecycle and diagnostics only. It
/// does not spawn a process, bind a listener, or pretend that the configured
/// controller endpoint is reachable. Native inbound listeners/connectors are
/// added behind this seam in subsequent migrations. Keeping this object
/// usable now lets tests prove that selecting native runtime cannot launch
/// Mihomo as a side effect.
final actor NativeRuntimeEngine: ProfileRuntimeSession {
    nonisolated let events: AsyncStream<CoreEvent>
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

    init() {
        let pair = AsyncStream<CoreEvent>.makeStream(
            of: CoreEvent.self,
            bufferingPolicy: .bufferingNewest(500)
        )
        events = pair.stream
        continuation = pair.continuation
        sessionState = nil
        sessionValidationError = nil
        outboundNodeTargets = nil
    }

    /// Creates an engine with a validated, MClash-owned policy snapshot.
    /// This initializer is intentionally separate from the no-argument
    /// compatibility initializer used by AppModel's opt-in switch.
    init(
        plan: CompiledRuntimePlan,
        listeners: MClashListenerRegistry,
        outboundNodeTargets: OutboundNodeTargetCatalog? = nil
    ) throws {
        let pair = AsyncStream<CoreEvent>.makeStream(
            of: CoreEvent.self,
            bufferingPolicy: .bufferingNewest(500)
        )
        events = pair.stream
        continuation = pair.continuation
        sessionState = try NativeRuntimeSessionState(plan: plan, listeners: listeners)
        sessionValidationError = nil
        listenerHandles = Self.makeListenerHandles(for: listeners)
        self.outboundNodeTargets = outboundNodeTargets
            ?? Self.makeOutboundNodeTargetCatalog(from: plan)
    }

    func configure(plan: CompiledRuntimePlan, listeners: MClashListenerRegistry) async throws {
        let state: NativeRuntimeSessionState
        do {
            state = try NativeRuntimeSessionState(plan: plan, listeners: listeners)
        } catch {
            sessionValidationError = error.localizedDescription
            throw error
        }
        sessionState = state
        listenerHandles = Self.makeListenerHandles(for: listeners)
        outboundNodeTargets = Self.makeOutboundNodeTargetCatalog(from: plan)
        // A policy reload may occur while the native runtime is active. The
        // Network Extension owns actual sockets, so refreshing the safe
        // handles is enough here; mirror the current running state for
        // enabled entrances without binding anything in this process.
        if currentState.isRunning {
            beginListeners()
        }
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
        outboundNodeTargets = catalog
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

        let decision = NativeRuleEngineProjection(plan: sessionState.plan).evaluate(context)
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
            sessionValidationError: sessionValidationError,
            listenerStates: listenerHandles.mapValues(\.state),
            connectorCapabilities: Self.connectorCapabilityMatrix(in: outboundNodeTargets),
            unsupportedConnectors: Self.unsupportedConnectors(in: outboundNodeTargets)
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

    private func beginListeners() {
        guard let registry = sessionState?.listeners else { return }
        for spec in registry.listeners {
            guard var handle = listenerHandles[spec.id] else { continue }
            handle.state = spec.enabled ? .starting : .stopped
            listenerHandles[spec.id] = handle
        }
        // Binding is deliberately represented by a handle only. Actual TCP
        // sockets are started by the Network Extension listener owner.
        for spec in registry.enabledListeners {
            guard var handle = listenerHandles[spec.id] else { continue }
            handle.state = .running
            listenerHandles[spec.id] = handle
        }
    }

    private func stopListeners() {
        for id in listenerHandles.keys {
            guard var handle = listenerHandles[id] else { continue }
            handle.state = .stopped
            listenerHandles[id] = handle
        }
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
