import Darwin
import Foundation
import Testing
@testable import MClashApp

@Suite("Core supervisor state isolation")
struct CoreSupervisorTests {
    @Test("Profile validation failure does not change the managed core state")
    func profileValidationDoesNotChangeManagedState() async {
        let supervisor = CoreSupervisor()

        do {
            try await supervisor.validateWithoutStateChanges(missingConfiguration())
            Issue.record("Expected validation to fail")
        } catch {
            // Expected: the binary does not exist.
        }

        #expect(await supervisor.state() == .stopped)
    }

    @Test("Managed validation failure leaves an explicit failed state")
    func managedValidationFailureLeavesFailedState() async {
        let supervisor = CoreSupervisor()

        do {
            try await supervisor.validate(missingConfiguration())
            Issue.record("Expected validation to fail")
        } catch {
            // Expected: the binary does not exist.
        }

        guard case .failed = await supervisor.state() else {
            Issue.record("Expected a failed core state")
            return
        }
    }

    @Test("Stopping the supervisor cancels an in-flight profile validation process")
    func stopCancelsProfileValidationProcess() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "mclash-cancel-validation-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let executable = root.appending(path: "slow-validator")
        try Data("#!/bin/sh\ntrap 'exit 130' TERM\nwhile :; do :; done\n".utf8)
            .write(to: executable)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executable.path
        )
        let configuration = root.appending(path: "profile.yaml")
        try Data("mixed-port: 7890\n".utf8).write(to: configuration)

        let supervisor = CoreSupervisor()
        let validation = Task {
            try await supervisor.validateWithoutStateChanges(
                CoreLaunchConfiguration(
                    binaryURL: executable,
                    homeDirectory: root.appending(path: "home", directoryHint: .isDirectory),
                    configURL: configuration,
                    controllerPort: 19_098,
                    secret: "test-secret"
                )
            )
        }

        try await Task.sleep(for: .milliseconds(100))
        await supervisor.stop()

        do {
            try await validation.value
            Issue.record("Expected validation cancellation")
        } catch is CancellationError {
            // Expected.
        } catch {
            Issue.record("Expected CancellationError, got \(error)")
        }
        #expect(await supervisor.state() == .stopped)
    }

    @Test("Profile validation has a deterministic deadline")
    func profileValidationTimesOut() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "mclash-validation-timeout-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let executable = root.appending(path: "hanging-validator")
        try Data("#!/bin/sh\ntrap '' TERM\nwhile :; do :; done\n".utf8).write(to: executable)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executable.path
        )
        let configurationURL = root.appending(path: "profile.yaml")
        try Data("mixed-port: 7890\n".utf8).write(to: configurationURL)
        let supervisor = CoreSupervisor(validationTimeout: 0.1)
        let configuration = CoreLaunchConfiguration(
            binaryURL: executable,
            homeDirectory: root.appending(path: "home", directoryHint: .isDirectory),
            configURL: configurationURL,
            controllerPort: 19_097,
            secret: "test-secret"
        )
        let clock = ContinuousClock()
        let startedAt = clock.now

        do {
            try await supervisor.validateWithoutStateChanges(configuration)
            Issue.record("Expected validation to time out")
        } catch let error as CoreSupervisorError {
            #expect(error == .configurationValidationTimedOut)
        } catch {
            Issue.record("Expected a deterministic timeout error, got \(error)")
        }

        #expect(startedAt.duration(to: clock.now) < .seconds(2))
        #expect(await supervisor.state() == .stopped)
    }

    @Test("Profile validation retains bounded diagnostic output")
    func profileValidationBoundsDiagnosticOutput() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "mclash-validation-output-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let executable = root.appending(path: "noisy-validator")
        try Data(
            "#!/bin/sh\ni=0\nwhile [ \"$i\" -lt 4096 ]; do printf x >&2; i=$((i + 1)); done\nexit 1\n".utf8
        ).write(to: executable)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executable.path
        )
        let configurationURL = root.appending(path: "profile.yaml")
        try Data("mixed-port: 7890\n".utf8).write(to: configurationURL)
        let retainedByteLimit = 64
        let supervisor = CoreSupervisor(
            validationTimeout: 2,
            maximumValidationOutputBytesPerStream: retainedByteLimit
        )
        let configuration = CoreLaunchConfiguration(
            binaryURL: executable,
            homeDirectory: root.appending(path: "home", directoryHint: .isDirectory),
            configURL: configurationURL,
            controllerPort: 19_096,
            secret: "test-secret"
        )

        do {
            try await supervisor.validateWithoutStateChanges(configuration)
            Issue.record("Expected validation to fail")
        } catch let error as CoreSupervisorError {
            guard case let .configurationInvalid(details) = error else {
                Issue.record("Expected bounded validation details, got \(error)")
                return
            }
            #expect(details.contains("[output truncated by MClash]"))
            #expect(details.utf8.count <= retainedByteLimit + 32)
        } catch {
            Issue.record("Expected CoreSupervisorError, got \(error)")
        }
    }

    @Test("A process still alive after forced termination leaves an explicit failed state")
    func stopFailureLeavesFailedState() async throws {
        let fixture = try StubbornCoreFixture()
        defer { fixture.cleanup() }
        try await fixture.start()

        let stopped = await fixture.supervisor.stop()

        #expect(!stopped)
        guard case let .failed(message) = await fixture.supervisor.state() else {
            Issue.record("Expected a failed core state after the stop deadline")
            return
        }
        #expect(message.contains("did not stop"))
        #expect(message.contains("PID"))

        fixture.allowForcedTermination()
        let cleanedUp = await fixture.supervisor.stop()
        #expect(cleanedUp)
        if cleanedUp { fixture.confirmStopped() }
        #expect(await fixture.supervisor.state() == .stopped)
    }

    private func missingConfiguration() -> CoreLaunchConfiguration {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        return CoreLaunchConfiguration(
            binaryURL: root.appending(path: "missing-core"),
            homeDirectory: root.appending(path: "home", directoryHint: .isDirectory),
            configURL: root.appending(path: "missing.yaml"),
            controllerPort: 19_099,
            secret: "test-secret"
        )
    }
}

final class StubbornCoreFixture: @unchecked Sendable {
    let supervisor: CoreSupervisor
    private let root: URL
    private let configuration: CoreLaunchConfiguration
    private let terminationGate: ForcedTerminationGate
    private let readyURL: URL

    init() throws {
        let terminationGate = ForcedTerminationGate()
        self.terminationGate = terminationGate
        root = FileManager.default.temporaryDirectory
            .appending(path: "mclash-stubborn-core-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let readyURL = root.appending(path: "ready")
        self.readyURL = readyURL
        let executable = root.appending(path: "stubborn-core")
        try Data(
            """
            #!/bin/sh
            if [ "$1" = "-t" ]; then
              exit 0
            fi
            trap '' TERM
            printf '%s' "$$" > '\(readyURL.path)'
            while :; do :; done
            """.utf8
        ).write(to: executable)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executable.path
        )

        let configurationURL = root.appending(path: "profile.yaml")
        try Data("mixed-port: 7890\n".utf8).write(to: configurationURL)
        let policy = CoreStopPolicy(
            gracefulPollAttempts: 5,
            gracefulPollInterval: .milliseconds(10),
            forcedPollAttempts: 5,
            forcedPollInterval: .milliseconds(10),
            forceTerminate: { [terminationGate] processIdentifier in
                terminationGate.forceTerminate(processIdentifier)
            }
        )
        supervisor = CoreSupervisor(
            stopPolicy: policy,
            readinessProbe: { _ in
                for _ in 0..<100 {
                    if FileManager.default.fileExists(atPath: readyURL.path) {
                        return "test-core"
                    }
                    try await Task.sleep(for: .milliseconds(10))
                }
                throw CoreSupervisorError.readinessTimedOut
            }
        )
        configuration = CoreLaunchConfiguration(
            binaryURL: executable,
            homeDirectory: root.appending(path: "home", directoryHint: .isDirectory),
            configURL: configurationURL,
            controllerPort: 19_095,
            secret: "test-secret"
        )
    }

    func start() async throws {
        try await supervisor.start(configuration)
    }

    func allowForcedTermination() {
        terminationGate.allowForcedTermination()
    }

    func confirmStopped() {
        terminationGate.confirmStopped()
        try? FileManager.default.removeItem(at: readyURL)
    }

    func cleanup() {
        terminationGate.cleanup()
        if let processIdentifier = try? String(contentsOf: readyURL, encoding: .utf8),
           let processIdentifier = Int32(processIdentifier) {
            _ = Darwin.kill(processIdentifier, SIGKILL)
        }
        try? FileManager.default.removeItem(at: root)
    }
}

private final class ForcedTerminationGate: @unchecked Sendable {
    private let lock = NSLock()
    private var forcedTerminationAllowed = false
    private var processIdentifier: Int32?

    func forceTerminate(_ processIdentifier: Int32) {
        let shouldTerminate = lock.withLock {
            self.processIdentifier = processIdentifier
            return forcedTerminationAllowed
        }
        if shouldTerminate {
            _ = Darwin.kill(processIdentifier, SIGKILL)
        }
    }

    func allowForcedTermination() {
        lock.withLock { forcedTerminationAllowed = true }
    }

    func confirmStopped() {
        lock.withLock { processIdentifier = nil }
    }

    func cleanup() {
        let processIdentifier = lock.withLock { self.processIdentifier }
        if let processIdentifier {
            _ = Darwin.kill(processIdentifier, SIGKILL)
        }
    }
}
