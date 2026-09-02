import Foundation
import Testing
@testable import MClashApp

@Suite("Native runtime controller seam")
struct NativeRuntimeControllerTests {
    @Test("Mihomo adapter preserves the stopped initial state")
    func mihomoAdapterPreservesInitialState() async {
        let supervisor = CoreSupervisor()
        let controller: any NativeRuntimeController =
            MihomoRuntimeControllerAdapter(supervisor: supervisor)

        #expect(await controller.state() == .stopped)
    }

    @Test("App-facing protocol forwards validation without starting a core")
    func validationForwardingKeepsStateStopped() async {
        let supervisor = CoreSupervisor()
        let controller: any NativeRuntimeController =
            MihomoRuntimeControllerAdapter(supervisor: supervisor)
        let root = FileManager.default.temporaryDirectory
            .appending(path: "mclash-runtime-controller-\(UUID().uuidString)",
                       directoryHint: .isDirectory)
        let configuration = CoreLaunchConfiguration(
            binaryURL: root.appending(path: "missing-core"),
            homeDirectory: root.appending(path: "home", directoryHint: .isDirectory),
            configURL: root.appending(path: "missing.yaml"),
            controllerPort: 19_099,
            secret: "test-secret"
        )

        do {
            try await controller.validateWithoutStateChanges(configuration)
            Issue.record("Expected validation to fail for missing configuration")
        } catch {
            // Expected: the adapter must preserve CoreSupervisor validation.
        }

        #expect(await controller.state() == .stopped)
    }
}
