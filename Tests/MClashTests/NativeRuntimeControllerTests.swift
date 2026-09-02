import Foundation
import Testing
import MClashNetworkShared
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

    @Test("Native session owns compiled policy and listeners without YAML")
    func nativeSessionOwnsPolicyAndListeners() async throws {
        let document = ConfigurationDocument.mclashDefault()
        let plan = try ConfigurationCompiler().compileRuntimePlan(document: document)
        let listener = try MClashListenerSpec(
            name: "Local HTTP",
            kind: .http,
            enabled: true,
            port: 18_080
        )
        let registry = try MClashListenerRegistry(listeners: [listener])
        let engine = try NativeRuntimeEngine(plan: plan, listeners: registry)

        let state = await engine.nativeSessionState()
        #expect(state?.plan == plan)
        #expect(state?.listeners == registry)

        let diagnostics = await engine.diagnostics()
        #expect(diagnostics.hasCompiledRuntimePlan)
        #expect(diagnostics.workspaceRevision == plan.workspaceRevision)
        #expect(diagnostics.listenerCount == 1)
        #expect(diagnostics.enabledListenerCount == 1)

        // A missing legacy YAML is intentional: native policy is complete
        // without rendering or reading Mihomo configuration.
        let root = FileManager.default.temporaryDirectory
            .appending(path: "mclash-native-policy-\\(UUID().uuidString)",
                       directoryHint: .isDirectory)
        let configuration = CoreLaunchConfiguration(
            binaryURL: root.appending(path: "mihomo-must-not-launch"),
            homeDirectory: root.appending(path: "home", directoryHint: .isDirectory),
            configURL: root.appending(path: "missing.yaml"),
            controllerPort: 19_101,
            secret: "native-policy-secret"
        )
        try await engine.start(configuration)
        #expect(await engine.nativeSessionState()?.plan == plan)
        #expect(await engine.diagnostics().listenerCount == 1)
        #expect(await engine.stop())
    }

    @Test("Native policy can be updated while the runtime is running")
    func nativePolicyUpdatesWhileRunning() async throws {
        let document = ConfigurationDocument.mclashDefault()
        let plan = try ConfigurationCompiler().compileRuntimePlan(document: document)
        let initialListener = try MClashListenerSpec(
            name: "Initial HTTP",
            kind: .http,
            enabled: true,
            port: 18_081
        )
        let initialRegistry = try MClashListenerRegistry(listeners: [initialListener])
        let engine = try NativeRuntimeEngine(plan: plan, listeners: initialRegistry)
        let root = FileManager.default.temporaryDirectory
            .appending(path: "mclash-native-policy-update-\(UUID().uuidString)",
                       directoryHint: .isDirectory)
        let configuration = CoreLaunchConfiguration(
            binaryURL: root.appending(path: "mihomo-must-not-launch"),
            homeDirectory: root.appending(path: "home", directoryHint: .isDirectory),
            configURL: root.appending(path: "missing.yaml"),
            controllerPort: 19_102,
            secret: "native-policy-update-secret"
        )
        try await engine.start(configuration)

        let updatedListener = try MClashListenerSpec(
            name: "Updated SOCKS",
            kind: .socks,
            enabled: true,
            port: 18_082
        )
        let updatedRegistry = try MClashListenerRegistry(listeners: [updatedListener])
        try await engine.configure(plan: plan, listeners: updatedRegistry)

        let diagnostics = await engine.diagnostics()
        #expect(diagnostics.state.isRunning)
        #expect(diagnostics.listenerCount == 1)
        #expect(diagnostics.enabledListenerCount == 1)
        #expect(await engine.nativeSessionState()?.listeners == updatedRegistry)
        #expect(await engine.stop())
    }

    @Test("Native engine manages listener handles without binding production sockets")
    func nativeListenerLifecycleUsesSafeHandles() async throws {
        let plan = try ConfigurationCompiler().compileRuntimePlan(
            document: ConfigurationDocument.mclashDefault()
        )
        let http = try MClashListenerSpec(
            name: "Native HTTP",
            kind: .http,
            enabled: true,
            port: 18_181
        )
        let app = try MClashListenerSpec(
            name: "Native App Routing",
            kind: .appRouting,
            enabled: false
        )
        let registry = try MClashListenerRegistry(listeners: [http, app])
        let engine = try NativeRuntimeEngine(plan: plan, listeners: registry)

        let before = await engine.nativeListenerHandles()
        #expect(before.count == 2)
        #expect(before.allSatisfy { $0.state == .stopped })
        #expect(before.allSatisfy { !$0.socketBound })

        let root = FileManager.default.temporaryDirectory
            .appending(path: "mclash-native-listeners-\(UUID().uuidString)",
                       directoryHint: .isDirectory)
        let configuration = CoreLaunchConfiguration(
            binaryURL: root.appending(path: "must-not-launch"),
            homeDirectory: root.appending(path: "home", directoryHint: .isDirectory),
            configURL: root.appending(path: "missing.yaml"),
            controllerPort: 19_131,
            secret: "native-listener-secret"
        )
        try await engine.start(configuration)

        let running = await engine.nativeListenerHandles()
        #expect(running.first(where: { $0.id == http.id })?.state == .running)
        #expect(running.first(where: { $0.id == app.id })?.state == .stopped)
        let diagnostics = await engine.diagnostics()
        #expect(diagnostics.listenerStates[http.id] == .running)
        #expect(diagnostics.listenerStates[app.id] == .stopped)
        #expect(diagnostics.listenerStates.values.filter { $0 == .running }.count == 1)
        #expect(!FileManager.default.fileExists(atPath: configuration.binaryURL.path))

        #expect(await engine.stop())
        let stopped = await engine.nativeListenerHandles()
        #expect(stopped.allSatisfy { $0.state == .stopped })
    }

    @Test("Native session rejects invalid policy before storing it")
    func nativeSessionRejectsInvalidPlan() throws {
        let valid = try ConfigurationCompiler().compileRuntimePlan(
            document: ConfigurationDocument.mclashDefault()
        )
        let missingGroup = ProxyGroupID()
        let invalid = CompiledRuntimePlan(
            workspaceID: valid.workspaceID,
            workspaceRevision: valid.workspaceRevision,
            nodes: valid.nodes,
            proxyGroups: valid.proxyGroups,
            rules: valid.rules,
            ruleSets: valid.ruleSets,
            dnsPolicy: valid.dnsPolicy,
            entrances: valid.entrances,
            routingMode: valid.routingMode,
            globalProxyGroupID: missingGroup,
            diagnostics: valid.diagnostics
        )
        let registry = try MClashListenerRegistry()

        #expect(throws: NativeRuntimeSessionValidationError.invalidPlan(
            .missingGlobalProxyGroup(missingGroup)
        )) {
            _ = try NativeRuntimeEngine(plan: invalid, listeners: registry)
        }
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
