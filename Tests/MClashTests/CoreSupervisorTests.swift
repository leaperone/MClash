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
