import Foundation
import MClashNetworkShared

/// Connector-neutral lifecycle surface used by the application model.
///
/// The first implementation still delegates to the bundled Mihomo process,
/// but keeping this boundary independent of its name lets the control plane
/// move to native connectors without changing AppModel's lifecycle code.
protocol NativeRuntimeController: AnyObject, Sendable {
    var events: AsyncStream<CoreEvent> { get }
    /// The control-plane implementation behind this lifecycle surface. This
    /// is deliberately observable so the UI/diagnostics can distinguish a
    /// native runtime from the legacy Mihomo adapter during migration.
    nonisolated var runtimeCapabilities: Set<NativeRuntimeCapability> { get }

    func state() async -> CoreRunState
    func diagnostics() async -> NativeRuntimeDiagnostics
    func start(_ configuration: CoreLaunchConfiguration) async throws
    @discardableResult
    func stop() async -> Bool
    func validate(_ configuration: CoreLaunchConfiguration) async throws
    func validateWithoutStateChanges(_ configuration: CoreLaunchConfiguration) async throws

    /// Attach MClash's connector-neutral policy snapshot to a native runtime.
    /// Legacy controllers intentionally ignore this state during migration.
    func configure(plan: CompiledRuntimePlan, listeners: MClashListenerRegistry) async throws

    /// Log forwarding is deliberately synchronous: CoreSupervisor uses this
    /// from pipe callbacks, and the gate itself is thread-safe.
    nonisolated func setProcessLogForwardingEnabled(_ enabled: Bool)
}

/// The implementation-neutral identity of a profile runtime session.
///
/// CoreFleetSupervisor uses this boundary instead of constructing a
/// CoreSupervisor directly.  A native session can therefore participate in
/// the same profile lifecycle while the legacy Mihomo adapter remains the
/// default for existing callers.
enum ProfileRuntimeSessionBackend: String, Codable, Equatable, Sendable {
    case native
    case mihomo
}

struct ProfileRuntimeSessionMetadata: Equatable, Sendable {
    let backend: ProfileRuntimeSessionBackend
    let capabilities: Set<NativeRuntimeCapability>

    init(
        backend: ProfileRuntimeSessionBackend,
        capabilities: Set<NativeRuntimeCapability>
    ) {
        self.backend = backend
        self.capabilities = capabilities
    }
}

/// A profile-scoped runtime owned by the connector-neutral fleet.
///
/// This intentionally inherits the existing lifecycle surface so the
/// migration is source-compatible with the Mihomo-backed implementation.
protocol ProfileRuntimeSession: NativeRuntimeController {
    nonisolated var metadata: ProfileRuntimeSessionMetadata { get }
}

extension CoreSupervisor: ProfileRuntimeSession {}

extension CoreSupervisor {
    nonisolated var metadata: ProfileRuntimeSessionMetadata {
        ProfileRuntimeSessionMetadata(
            backend: .mihomo,
            capabilities: runtimeCapabilities
        )
    }

    nonisolated var runtimeCapabilities: Set<NativeRuntimeCapability> {
        [.legacyCore, .legacyController]
    }

    func diagnostics() async -> NativeRuntimeDiagnostics {
        let current = state()
        return NativeRuntimeDiagnostics(
            state: current,
            capabilities: runtimeCapabilities,
            backend: "mihomo",
            controlPlaneAvailable: current.isRunning,
            lastError: nil,
            startedAt: current.session?.startedAt,
            hasCompiledRuntimePlan: false,
            workspaceRevision: nil,
            listenerCount: 0,
            enabledListenerCount: 0,
            sessionValidationError: nil,
            listenerStates: [:],
            connectorCapabilities: [],
            unsupportedConnectors: []
        )
    }

    func configure(plan: CompiledRuntimePlan, listeners: MClashListenerRegistry) async throws {
        // CoreSupervisor remains the legacy Mihomo adapter. Native policy is
        // consumed only by NativeRuntimeEngine.
    }
}

/// Compatibility adapter for the current Mihomo-backed runtime.
///
/// No behavior is added here: the adapter forwards lifecycle operations to
/// CoreSupervisor verbatim. It is intentionally a separate type so a native
/// runtime can replace it at the AppModel boundary in a later migration.
final actor MihomoRuntimeControllerAdapter: ProfileRuntimeSession {
    nonisolated let events: AsyncStream<CoreEvent>
    nonisolated var runtimeCapabilities: Set<NativeRuntimeCapability> {
        [.legacyCore, .legacyController]
    }
    nonisolated var metadata: ProfileRuntimeSessionMetadata {
        ProfileRuntimeSessionMetadata(
            backend: .mihomo,
            capabilities: runtimeCapabilities
        )
    }
    private let supervisor: CoreSupervisor

    init(supervisor: CoreSupervisor = CoreSupervisor()) {
        self.supervisor = supervisor
        events = supervisor.events
    }

    func state() async -> CoreRunState {
        await supervisor.state()
    }

    func diagnostics() async -> NativeRuntimeDiagnostics {
        await supervisor.diagnostics()
    }

    func start(_ configuration: CoreLaunchConfiguration) async throws {
        try await supervisor.start(configuration)
    }

    @discardableResult
    func stop() async -> Bool {
        await supervisor.stop()
    }

    func validate(_ configuration: CoreLaunchConfiguration) async throws {
        try await supervisor.validate(configuration)
    }

    func validateWithoutStateChanges(_ configuration: CoreLaunchConfiguration) async throws {
        try await supervisor.validateWithoutStateChanges(configuration)
    }

    func configure(plan: CompiledRuntimePlan, listeners: MClashListenerRegistry) async throws {
        // Keep the legacy adapter's behavior unchanged while native runtime is
        // opt-in. The arguments are intentionally not rendered to Mihomo.
    }

    nonisolated func setProcessLogForwardingEnabled(_ enabled: Bool) {
        supervisor.setProcessLogForwardingEnabled(enabled)
    }
}
