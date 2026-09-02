import Foundation

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
final actor NativeRuntimeEngine: NativeRuntimeController {
    nonisolated let events: AsyncStream<CoreEvent>
    nonisolated let runtimeCapabilities: Set<NativeRuntimeCapability> = [
        .nativeRuntime,
        .nativeRouting,
        .nativeDNS
    ]

    private let continuation: AsyncStream<CoreEvent>.Continuation
    private var currentState: CoreRunState = .stopped
    private var lastError: String?
    private var startedAt: Date?

    init() {
        let pair = AsyncStream<CoreEvent>.makeStream(
            of: CoreEvent.self,
            bufferingPolicy: .bufferingNewest(500)
        )
        events = pair.stream
        continuation = pair.continuation
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
            startedAt: startedAt
        )
    }

    func start(_ configuration: CoreLaunchConfiguration) async throws {
        guard !currentState.isRunning else {
            throw CoreSupervisorError.alreadyRunning
        }
        try await validateConfiguration(configuration)
        transition(to: .starting)
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
        guard FileManager.default.fileExists(
            atPath: configuration.homeDirectory.path,
            isDirectory: &isDirectory
        ) else {
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

    private func emitLog(_ message: String) {
        continuation.yield(.log(CoreLogLine(stream: .supervisor, message: message)))
    }
}
