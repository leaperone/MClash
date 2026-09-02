import Foundation
import Testing
@testable import MClashApp

@Suite("Native runtime controller seam")
struct NativeRuntimeControllerTests {
    @Test("AppModel runtime selection is explicit and opt-in")
    func appModelRuntimeSelectionIsExplicit() async {
        let native = AppModel.runtimeController(
            environment: ["MCLASH_NATIVE_RUNTIME": "1"]
        )
        #expect(await native.diagnostics().backend == "native")
        #expect(await native.diagnostics().capabilities.contains(.nativeRuntime))

        let legacy = AppModel.runtimeController(environment: [:])
        #expect(await legacy.diagnostics().backend == "mihomo")
        #expect(!(await legacy.diagnostics().capabilities.contains(.nativeRuntime)))
    }

    @Test("Native AppModel runtime lifecycle never contacts a controller")
    func nativeRuntimeLifecycleIsControllerFree() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "mclash-native-lifecycle-\(UUID().uuidString)",
                       directoryHint: .isDirectory)
        let controller = AppModel.runtimeController(
            environment: ["MCLASH_NATIVE_RUNTIME": "1"]
        )
        let configuration = CoreLaunchConfiguration(
            binaryURL: root.appending(path: "must-not-launch"),
            homeDirectory: root.appending(path: "home", directoryHint: .isDirectory),
            configURL: root.appending(path: "missing.yaml"),
            controllerPort: 19_097,
            secret: "native-lifecycle-secret"
        )

        try await controller.start(configuration)
        #expect(await controller.state().isRunning)
        let diagnostics = await controller.diagnostics()
        #expect(diagnostics.controlPlaneAvailable == false)
        #expect(diagnostics.backend == "native")
        // A native start accepts a missing legacy YAML and never creates or
        // executes the configured binary.
        #expect(!FileManager.default.fileExists(atPath: configuration.binaryURL.path))
        #expect(await controller.stop())
        #expect(await controller.state() == .stopped)
    }

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
