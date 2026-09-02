import Foundation

/// Connector-neutral lifecycle surface used by the application model.
///
/// The first implementation still delegates to the bundled Mihomo process,
/// but keeping this boundary independent of its name lets the control plane
/// move to native connectors without changing AppModel's lifecycle code.
protocol NativeRuntimeController: AnyObject, Sendable {
    var events: AsyncStream<CoreEvent> { get }

    func state() async -> CoreRunState
    func start(_ configuration: CoreLaunchConfiguration) async throws
    @discardableResult
    func stop() async -> Bool
    func validate(_ configuration: CoreLaunchConfiguration) async throws
    func validateWithoutStateChanges(_ configuration: CoreLaunchConfiguration) async throws

    /// Log forwarding is deliberately synchronous: CoreSupervisor uses this
    /// from pipe callbacks, and the gate itself is thread-safe.
    nonisolated func setProcessLogForwardingEnabled(_ enabled: Bool)
}

extension CoreSupervisor: NativeRuntimeController {}

/// Compatibility adapter for the current Mihomo-backed runtime.
///
/// No behavior is added here: the adapter forwards lifecycle operations to
/// CoreSupervisor verbatim. It is intentionally a separate type so a native
/// runtime can replace it at the AppModel boundary in a later migration.
final actor MihomoRuntimeControllerAdapter: NativeRuntimeController {
    nonisolated let events: AsyncStream<CoreEvent>
    private let supervisor: CoreSupervisor

    init(supervisor: CoreSupervisor = CoreSupervisor()) {
        self.supervisor = supervisor
        events = supervisor.events
    }

    func state() async -> CoreRunState {
        await supervisor.state()
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

    nonisolated func setProcessLogForwardingEnabled(_ enabled: Bool) {
        supervisor.setProcessLogForwardingEnabled(enabled)
    }
}
