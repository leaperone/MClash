import Foundation
import Testing
@testable import MClashApp

@Suite("Native runtime controller seam")
struct NativeRuntimeControllerTests {
    @Test("Native engine starts without a Mihomo YAML or process")
    func nativeEngineStartsWithoutLegacyConfiguration() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "mclash-native-runtime-\(UUID().uuidString)",
                       directoryHint: .isDirectory)
        let configuration = CoreLaunchConfiguration(
            binaryURL: root.appending(path: "mihomo-must-not-launch"),
            homeDirectory: root.appending(path: "home", directoryHint: .isDirectory),
            configURL: root.appending(path: "missing.yaml"),
            controllerPort: 19_099,
            secret: "native-test-secret"
        )
        let engine = NativeRuntimeEngine()

        try await engine.start(configuration)

        guard case let .running(session) = await engine.state() else {
            Issue.record("Expected native engine to be running")
            return
        }
        #expect(session.version == "native")
        #expect(await engine.diagnostics().backend == "native")
        #expect(await engine.diagnostics().controlPlaneAvailable == false)
        #expect(FileManager.default.fileExists(atPath: configuration.homeDirectory.path))
        #expect(!FileManager.default.fileExists(atPath: configuration.binaryURL.path))
        #expect(await engine.stop())
    }

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
