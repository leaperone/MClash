import Foundation
import MClashNetworkShared
import Testing
@testable import MClashApp

@Suite("App model network safety")
struct AppModelSafetyTests {
    @MainActor
    @Test("Storage initialization failures remain visible instead of looking like empty data")
    func storageInitializationFailuresAreDurableOperationalIssues() throws {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "mclash-unavailable-storage-\(UUID().uuidString)"
        )
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("not a directory".utf8).write(to: root)

        let model = AppModel(
            profileDirectoryLayout: ProfileDirectoryLayout(rootDirectory: root)
        )

        let components = Set(model.storageInitializationFailures.map(\.component))
        #expect(components.contains(.profiles))
        #expect(components.contains(.runtimeOverrides))
        #expect(components.contains(.systemProxySettings))
        #expect(components.contains(.appRoutingSettings))
        #expect(model.profiles.isEmpty)

        let profileIssue = try #require(
            model.operationalIssues.first { $0.id == "storage.profiles" }
        )
        #expect(profileIssue.severity == .error)
        #expect(profileIssue.consequence.contains("does not mean your profiles were deleted"))
        #expect(profileIssue.technicalDetail?.contains("Recovery:") == true)

        model.errorMessage = "An unrelated transient error"
        #expect(model.operationalIssues.contains { $0.id == "storage.profiles" })
    }

    @MainActor
    @Test("Invalid saved settings remain a durable operational issue after startup")
    func invalidSavedSettingsDoNotCollapseIntoTransientErrorMessage() async throws {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "mclash-invalid-runtime-settings-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let layout = ProfileDirectoryLayout(rootDirectory: root)
        try layout.createDirectories()
        let storageLayout = RuntimeOverrideStorageLayout(applicationRoot: root)
        try FileManager.default.createDirectory(
            at: storageLayout.settingsDirectory,
            withIntermediateDirectories: true
        )
        try Data(#"{"schemaVersion":999,"overrides":{}}"#.utf8)
            .write(to: storageLayout.overridesURL)
        let model = AppModel(profileDirectoryLayout: layout)

        await model.prepare()

        #expect(
            model.storageInitializationFailures.contains {
                $0.component == .runtimeOverrides
            }
        )
        #expect(model.operationalIssues.contains { $0.id == "storage.runtime-overrides" })
        model.errorMessage = nil
        #expect(model.operationalIssues.contains { $0.id == "storage.runtime-overrides" })
    }

    @MainActor
    @Test("System proxy guard becomes unverified after repeated failures and recovers")
    func systemProxyGuardFailureIsPersistentAndRecoverable() async throws {
        let endpoints = try LocalSystemProxyEndpoints(
            http: SystemProxyEndpoint(port: 7890),
            https: SystemProxyEndpoint(port: 7890),
            socks: SystemProxyEndpoint(port: 7891)
        )
        let backend = GuardVerificationBackend(
            endpoints: endpoints,
            failedReads: AppModel.systemProxyGuardFailureThreshold
        )
        let model = AppModel(
            systemProxyManager: SystemProxyManager(backend: backend)
        )
        model.systemProxyState = .on

        for expectedCount in 1...AppModel.systemProxyGuardFailureThreshold {
            await model.performSystemProxyGuardCheck(
                endpoints: endpoints,
                bypassDomains: []
            )
            #expect(model.systemProxyGuardFailure?.consecutiveFailures == expectedCount)
        }

        guard case let .failed(message) = model.systemProxyState else {
            Issue.record("Expected repeated guard failures to leave the proxy unverified")
            return
        }
        #expect(message.contains("3 consecutive attempts"))
        let guardIssue = try #require(
            model.operationalIssues.first { $0.id == "system-proxy.guard" }
        )
        #expect(guardIssue.primaryActionTitle == "Turn Off & Restore")
        #expect(guardIssue.primaryAction == .restoreSystemProxy)
        #expect(model.errorMessage == nil)

        await model.performSystemProxyGuardCheck(
            endpoints: endpoints,
            bypassDomains: []
        )

        #expect(model.systemProxyState == .on)
        #expect(model.systemProxyGuardFailure == nil)
        #expect(model.systemProxyGuardLastVerifiedAt != nil)
        #expect(!model.operationalIssues.contains { $0.id == "system-proxy.guard" })
    }

    @MainActor
    @Test("App Routing provider drift must be consecutive before capture is declared failed")
    func appRoutingProviderRuntimeDriftIsVerified() async throws {
        let revision: UInt64 = 42
        let mismatched = TransparentProxyProviderStatus(
            revision: 41,
            running: true,
            captureEnabled: true,
            failOpen: true
        )
        let healthy = TransparentProxyProviderStatus(
            revision: revision,
            running: true,
            captureEnabled: true,
            failOpen: true
        )
        let control = AppRoutingRuntimeStatusControl(
            statuses: [mismatched, mismatched, healthy, mismatched, mismatched, mismatched]
        )
        let model = AppModel(networkExtensionControl: control)

        #expect(!(await model.verifyAppRoutingProviderRuntime(expectedRevision: revision)))
        #expect(!(await model.verifyAppRoutingProviderRuntime(expectedRevision: revision)))
        #expect(model.appRoutingProviderStatusFailureCount == 2)
        #expect(model.degradedStreams.contains(.appRouting))

        #expect(await model.verifyAppRoutingProviderRuntime(expectedRevision: revision))
        #expect(model.appRoutingProviderStatusFailureCount == 0)
        #expect(model.appRoutingProviderLastVerifiedAt != nil)
        #expect(!model.degradedStreams.contains(.appRouting))

        #expect(!(await model.verifyAppRoutingProviderRuntime(expectedRevision: revision)))
        #expect(!(await model.verifyAppRoutingProviderRuntime(expectedRevision: revision)))
        #expect(!(await model.verifyAppRoutingProviderRuntime(expectedRevision: revision)))

        guard case let .failed(message) = model.networkCaptureState else {
            Issue.record("Expected repeated provider drift to fail App Routing")
            return
        }
        #expect(message.contains("3 consecutive provider checks"))
        #expect(message.contains("Expected active revision 42"))
        #expect(model.errorMessage == nil)
        #expect(model.operationalIssues.contains { $0.id == "app-routing.failed" })
        #expect(await control.providerStatusRequestCount == 6)
    }

    @MainActor
    @Test("A failed proxy activation without a snapshot does not lock the application")
    func failedActivationWithoutSnapshotIsDismissible() throws {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "mclash-no-recovery-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let layout = ProfileDirectoryLayout(rootDirectory: root)
        try layout.createDirectories()
        let model = AppModel(
            systemProxyManager: SystemProxyManager(backend: RestoreBackend(failsRestore: false)),
            profileDirectoryLayout: layout
        )
        model.systemProxyState = .failed("Permission was not granted.")
        model.errorMessage = "Permission was not granted."

        #expect(!model.systemProxyRecoveryRequired)
        #expect(!model.systemProxyEnabled)
        #expect(model.canPerform(.connection))
    }

    @MainActor
    @Test("Shutdown is cancelled when the previous system proxy cannot be restored")
    func shutdownStopsWhenProxyRestoreFails() async throws {
        let fixture = try Fixture(failsRestore: true)
        defer { fixture.cleanup() }

        let canTerminate = await fixture.model.shutdown()

        #expect(!canTerminate)
        #expect(FileManager.default.fileExists(atPath: fixture.snapshotURL.path))
        guard case .failed = fixture.model.systemProxyState else {
            Issue.record("Expected a failed system proxy state")
            return
        }
    }

    @MainActor
    @Test("Launch preparation does not loop on a failed system proxy restore")
    func preparationDoesNotRepeatFailedProxyRestore() async throws {
        let fixture = try Fixture(failsRestore: true)
        defer { fixture.cleanup() }

        await fixture.model.prepare()
        await fixture.model.prepare()

        #expect(fixture.backend.applyCount == 1)
        #expect(fixture.model.systemProxyRecoveryRequired)
        #expect(!fixture.model.isConnected)
        if case let .failed(message) = fixture.model.systemProxyState {
            #expect(fixture.model.errorMessage == message)
            #expect(!message.contains("running core was left active"))
        } else {
            Issue.record("Expected the precise system proxy restoration failure")
        }
    }

    @MainActor
    @Test("Shutdown serializes with in-flight startup preparation")
    func shutdownWaitsForStartupPreparation() async throws {
        let fixture = try Fixture(failsRestore: false, restoreDelay: 0.1)
        defer { fixture.cleanup() }

        let preparation = Task { @MainActor in
            await fixture.model.prepare()
        }
        for _ in 0..<100 where fixture.backend.applyCount == 0 {
            try await Task.sleep(for: .milliseconds(2))
        }
        #expect(fixture.backend.applyCount == 1)

        let canTerminate = await fixture.model.shutdown()
        await preparation.value

        #expect(canTerminate)
        #expect(!fixture.model.isConnected)
        #expect(fixture.model.systemProxyState == .off)
        #expect(!FileManager.default.fileExists(atPath: fixture.snapshotURL.path))
        #expect(fixture.backend.applyCount == 1)
    }

    @MainActor
    @Test("Successful shutdown restores and removes the persisted system proxy snapshot")
    func shutdownRestoresProxySnapshot() async throws {
        let fixture = try Fixture(failsRestore: false)
        defer { fixture.cleanup() }

        let canTerminate = await fixture.model.shutdown()

        #expect(canTerminate)
        #expect(!FileManager.default.fileExists(atPath: fixture.snapshotURL.path))
        #expect(fixture.model.systemProxyState == .off)
        #expect(fixture.backend.applyCount == 1)
    }

    @MainActor
    @Test("Disconnect keeps a failed state when the core cannot be stopped")
    func disconnectReportsCoreStopFailure() async throws {
        let coreFixture = try StubbornCoreFixture()
        defer { coreFixture.cleanup() }
        try await coreFixture.start()
        let model = AppModel(supervisor: coreFixture.supervisor)

        await model.disconnect()

        guard case let .failed(message) = model.coreState else {
            Issue.record("Expected disconnect to retain the core stop failure")
            return
        }
        #expect(message.contains("did not stop"))
        #expect(model.errorMessage == message)

        coreFixture.allowForcedTermination()
        let cleanedUp = await coreFixture.supervisor.stop()
        #expect(cleanedUp)
        if cleanedUp { coreFixture.confirmStopped() }
    }

    @MainActor
    @Test("Shutdown is cancelled when the core cannot be stopped")
    func shutdownReportsCoreStopFailure() async throws {
        let coreFixture = try StubbornCoreFixture()
        defer { coreFixture.cleanup() }
        try await coreFixture.start()
        let fixture = try Fixture(
            failsRestore: false,
            supervisor: coreFixture.supervisor
        )
        defer { fixture.cleanup() }

        let canTerminate = await fixture.model.shutdown()

        #expect(!canTerminate)
        guard case let .failed(message) = fixture.model.coreState else {
            Issue.record("Expected shutdown to retain the core stop failure")
            return
        }
        #expect(message.contains("did not stop"))
        #expect(fixture.model.errorMessage == message)

        coreFixture.allowForcedTermination()
        let cleanedUp = await coreFixture.supervisor.stop()
        #expect(cleanedUp)
        if cleanedUp { coreFixture.confirmStopped() }
    }

    @MainActor
    @Test("Proxy presentation follows runtime YAML order and resolves nested selections")
    func proxyPresentationUsesProfileOrder() throws {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "mclash-proxy-presentation-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let layout = ProfileDirectoryLayout(rootDirectory: root)
        try layout.createDirectories()
        try Data(
            """
            proxy-groups:
              - name: Group B
                type: select
                proxies: [Group A]
              - name: Group A
                type: select
                proxies: [Node]
            """.utf8
        ).write(to: layout.runtimeConfigurationURL)
        let model = AppModel(profileDirectoryLayout: layout)
        model.activeConfigURL = layout.runtimeConfigurationURL
        let collection = try JSONDecoder().decode(
            MihomoProxyCollection.self,
            from: Data(
                #"{"proxies":{"Node":{"name":"Node","type":"Shadowsocks"},"Group A":{"name":"Group A","type":"Selector","all":["Node"],"now":"Node"},"GLOBAL":{"name":"GLOBAL","type":"Selector","all":["Group B"],"now":"Group B"},"Group B":{"name":"Group B","type":"Selector","all":["Group A"],"now":"Group A"}}}"#.utf8
            )
        )

        model.applyProxyCollection(collection)

        #expect(model.proxyGroups.map(\.name) == ["Group B", "Group A"])
        #expect(model.proxySelectionPaths["Group B"]?.route == ["Group B", "Group A", "Node"])
        #expect(model.proxySelectionPaths["Group B"]?.terminal == "Node")
        #expect(model.proxyGroups(forRoutingMode: "rule").map(\.name) == ["Group B", "Group A"])
        #expect(model.proxyGroups(forRoutingMode: "global").map(\.name) == ["GLOBAL"])
        #expect(model.proxyGroups(forRoutingMode: "direct").isEmpty)
        #expect(
            ProxyGroupPartitionSnapshot(model: model, routingMode: "rule")
                .orderedForPresentation
                .map(\.name) == ["Group A", "Group B"]
        )

        model.rules = try JSONDecoder().decode(
            [MihomoRule].self,
            from: Data(
                #"[{"index":0,"type":"MATCH","payload":"","proxy":"GLOBAL","size":0}]"#.utf8
            )
        )
        #expect(
            model.proxyGroups(forRoutingMode: "rule").map(\.name)
                == ["Group B", "Group A", "GLOBAL"]
        )
        #expect(
            ProxyGroupPartitionSnapshot(model: model, routingMode: "rule")
                .orderedForPresentation
                .map(\.name) == ["Group A", "Group B", "GLOBAL"]
        )
    }

    @MainActor
    @Test("Connection snapshots feed bounded observed route traffic")
    func connectionSnapshotsFeedTrafficAttribution() throws {
        let model = AppModel()
        model.applyConnectionSnapshot(
            try connectionSnapshot(upload: 10, download: 20),
            generation: 7
        )
        model.applyConnectionSnapshot(
            try connectionSnapshot(upload: 16, download: 29),
            generation: 7
        )

        let entry = try #require(model.routeTrafficEntries.first)
        #expect(entry.uploadDelta == 6)
        #expect(entry.downloadDelta == 9)
        #expect(entry.routing.destination == "example.com")
        #expect(entry.routing.chains == ["Proxy", "Node"])
    }

    @MainActor
    @Test("Deep-link subscriptions wait for confirmation and do not become active")
    func deepLinkSubscriptionsRequireConfirmation() async throws {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "mclash-deep-link-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let validator = root.appending(path: "validator")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: validator)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: validator.path
        )
        let layout = ProfileDirectoryLayout(rootDirectory: root.appending(path: "data"))
        let downloader = DeepLinkSubscriptionDownloader()
        let store = try ProfileStore(layout: layout, downloader: downloader)
        let model = AppModel(
            binaryLocator: CoreBinaryLocator(bundledBinaryURLs: [validator]),
            profileDirectoryLayout: layout,
            profileStoreOverride: store
        )
        let incomingURL = try #require(
            URL(
                string: "mclash://subscribe?url=https%3A%2F%2Fexample.com%2Fprofile.yaml&name=Work"
            )
        )

        await model.handleIncomingURL(incomingURL)

        let pending = try #require(model.pendingSubscriptionImport)
        #expect(pending.displayHost == "example.com")
        #expect(await downloader.requestCount == 0)
        #expect(model.profiles.isEmpty)
        #expect(model.activeProfileID == nil)

        await model.confirmPendingSubscriptionImport(pending)

        #expect(model.pendingSubscriptionImport == nil)
        #expect(await downloader.requestCount == 1)
        #expect(model.profiles.count == 1)
        #expect(model.activeProfileID == nil)
        #expect(try await store.activeProfileID() == nil)
    }

    @MainActor
    @Test("Group-specific delay histories never leak across test URLs")
    func groupSpecificDelaysStayIsolated() throws {
        let model = AppModel()
        let collection = try JSONDecoder().decode(
            MihomoProxyCollection.self,
            from: Data(
                #"""
                {
                  "proxies": {
                    "Node": {
                      "name": "Node",
                      "type": "Shadowsocks",
                      "history": [{"time":"now","delay":15}],
                      "extra": {
                        "https://a.example/test": {
                          "alive": true,
                          "history": [{"time":"now","delay":100}]
                        },
                        "https://b.example/test": {
                          "alive": false,
                          "history": [{"time":"now","delay":320}]
                        }
                      }
                    },
                    "Group A": {
                      "name": "Group A",
                      "type": "URLTest",
                      "all": ["Node"],
                      "now": "Node",
                      "testUrl": "https://a.example/test"
                    },
                    "Group B": {
                      "name": "Group B",
                      "type": "URLTest",
                      "all": ["Node"],
                      "now": "Node",
                      "testUrl": "https://b.example/test"
                    }
                  }
                }
                """#.utf8
            )
        )

        model.applyProxyCollection(collection)

        #expect(model.proxyDelay(for: "Node", in: "Group A") == 100)
        #expect(model.proxyDelay(for: "Node", in: "Group B") == nil)
        #expect(model.proxyDelayMap(for: "Group A") == ["Node": 100])
        #expect(model.proxyDelayMap(for: "Group B").isEmpty)
        #expect(model.proxyAlive(for: "Node", in: "Group A") == true)
        #expect(model.proxyAlive(for: "Node", in: "Group B") == false)
    }

    @MainActor
    @Test("Status-only proxy refreshes reuse the stable topology")
    func statusRefreshReusesTopology() throws {
        let model = AppModel()
        let initial = try makeProxyCollection([
            ProxyTestSpec(name: "Group", type: "Selector", all: ["Node"], now: "Node"),
            ProxyTestSpec(name: "Node", type: "Shadowsocks", alive: true),
        ])
        model.applyProxyCollection(initial)
        let initialTopology = model.proxyTopology

        let refreshed = try JSONDecoder().decode(
            MihomoProxyCollection.self,
            from: Data(
                #"{"proxies":{"Group":{"name":"Group","type":"Selector","all":["Node"],"now":"Node","alive":true},"Node":{"name":"Node","type":"Shadowsocks","alive":false,"history":[{"time":"now","delay":42}]}}}"#.utf8
            )
        )
        model.applyProxyCollection(refreshed, profileStructure: .empty)

        #expect(model.proxyTopology == initialTopology)
        #expect(model.proxiesByName["Node"]?.alive == false)
        #expect(model.proxyDelay(for: "Node", in: nil) == 42)

        let selectionChanged = try makeProxyCollection([
            ProxyTestSpec(
                name: "Group",
                type: "Selector",
                all: ["Node", "Backup"],
                now: "Backup"
            ),
            ProxyTestSpec(name: "Node", type: "Shadowsocks", alive: false),
            ProxyTestSpec(name: "Backup", type: "Direct"),
        ])
        model.applyProxyCollection(selectionChanged, profileStructure: .empty)

        #expect(model.proxySelectionPaths["Group"]?.terminal == "Backup")
        #expect(model.proxyTopology != initialTopology)
    }

    private func connectionSnapshot(upload: Int64, download: Int64) throws -> MihomoConnectionSnapshot {
        let object: [String: Any] = [
            "downloadTotal": download,
            "uploadTotal": upload,
            "memory": 0,
            "connections": [
                [
                    "id": "connection-1",
                    "metadata": ["host": "example.com", "destinationIP": "1.1.1.1"],
                    "upload": upload,
                    "download": download,
                    "start": "2026-07-16T08:00:00+08:00",
                    "chains": ["Node", "Proxy"],
                    "providerChains": [],
                    "rule": "DomainSuffix",
                    "rulePayload": "example.com"
                ]
            ]
        ]
        return try JSONDecoder().decode(
            MihomoConnectionSnapshot.self,
            from: JSONSerialization.data(withJSONObject: object)
        )
    }
}

private actor DeepLinkSubscriptionDownloader: SubscriptionDownloading {
    private(set) var requestCount = 0

    func download(_ request: URLRequest) async throws -> SubscriptionDownloadResponse {
        requestCount += 1
        return SubscriptionDownloadResponse(
            statusCode: 200,
            data: Data("mixed-port: 7890\n".utf8)
        )
    }
}

@MainActor
private struct Fixture {
    let root: URL
    let snapshotURL: URL
    let backend: RestoreBackend
    let model: AppModel

    init(
        failsRestore: Bool,
        restoreDelay: TimeInterval = 0,
        supervisor: CoreSupervisor = CoreSupervisor()
    ) throws {
        root = FileManager.default.temporaryDirectory
            .appending(path: "mclash-app-model-\(UUID().uuidString)", directoryHint: .isDirectory)
        let layout = ProfileDirectoryLayout(rootDirectory: root)
        try layout.createDirectories()

        let service = SystemProxyNetworkService(id: "wifi", name: "Wi-Fi")
        let state = try SystemProxyServiceState(
            service: service,
            protocolExists: true,
            configuration: [SystemProxyKeys.httpEnable: .integer(0)]
        )
        backend = RestoreBackend(failsRestore: failsRestore, restoreDelay: restoreDelay)
        let manager = SystemProxyManager(backend: backend)
        snapshotURL = layout.stateDirectory.appending(path: "system-proxy-snapshot.json")
        try JSONEncoder().encode(SystemProxySnapshot(services: [state]))
            .write(to: snapshotURL, options: .atomic)

        model = AppModel(
            supervisor: supervisor,
            systemProxyManager: manager,
            profileDirectoryLayout: layout
        )
        model.systemProxyState = .on
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }
}

private final class RestoreBackend: SystemProxyBackend, @unchecked Sendable {
    private let lock = NSLock()
    private let failsRestore: Bool
    private let restoreDelay: TimeInterval
    private var storedApplyCount = 0

    init(failsRestore: Bool, restoreDelay: TimeInterval = 0) {
        self.failsRestore = failsRestore
        self.restoreDelay = restoreDelay
    }

    var applyCount: Int {
        lock.withLock { storedApplyCount }
    }

    func enabledNetworkServices() throws -> [SystemProxyNetworkService] { [] }

    func proxyStates(
        for services: [SystemProxyNetworkService]
    ) throws -> [SystemProxyServiceState] {
        []
    }

    func applyProxyStates(_ states: [SystemProxyServiceState]) throws {
        lock.withLock { storedApplyCount += 1 }
        if restoreDelay > 0 {
            Thread.sleep(forTimeInterval: restoreDelay)
        }
        if failsRestore { throw SystemProxyError.applyFailed }
    }
}

private final class GuardVerificationBackend: SystemProxyBackend, @unchecked Sendable {
    private let lock = NSLock()
    private let service = SystemProxyNetworkService(id: "wifi", name: "Wi-Fi")
    private let matchingState: SystemProxyServiceState
    private var remainingFailedReads: Int

    init(endpoints: LocalSystemProxyEndpoints, failedReads: Int) {
        remainingFailedReads = failedReads
        matchingState = try! SystemProxyServiceState(
            service: service,
            protocolExists: true,
            configuration: [
                SystemProxyKeys.httpEnable: .integer(1),
                SystemProxyKeys.httpHost: .string(endpoints.http.host),
                SystemProxyKeys.httpPort: .integer(Int64(endpoints.http.port)),
                SystemProxyKeys.httpsEnable: .integer(1),
                SystemProxyKeys.httpsHost: .string(endpoints.https.host),
                SystemProxyKeys.httpsPort: .integer(Int64(endpoints.https.port)),
                SystemProxyKeys.socksEnable: .integer(1),
                SystemProxyKeys.socksHost: .string(endpoints.socks.host),
                SystemProxyKeys.socksPort: .integer(Int64(endpoints.socks.port)),
                SystemProxyKeys.exceptionsList: .array([]),
            ]
        )
    }

    func enabledNetworkServices() throws -> [SystemProxyNetworkService] {
        [service]
    }

    func proxyStates(
        for services: [SystemProxyNetworkService]
    ) throws -> [SystemProxyServiceState] {
        try lock.withLock {
            if remainingFailedReads > 0 {
                remainingFailedReads -= 1
                throw SystemProxyError.preferencesUnavailable
            }
            return [matchingState]
        }
    }

    func applyProxyStates(_ states: [SystemProxyServiceState]) throws {}
}

private actor AppRoutingRuntimeStatusControl: NetworkExtensionControlling {
    private var statuses: [TransparentProxyProviderStatus]
    private(set) var providerStatusRequestCount = 0

    init(statuses: [TransparentProxyProviderStatus]) {
        self.statuses = statuses
    }

    func enable(
        _ configuration: NetworkExtensionRuntimeConfiguration,
        progress reportProgress: @escaping @Sendable (NetworkExtensionEnableProgress) -> Void
    ) async throws -> NetworkExtensionEnableOutcome {
        .running
    }

    func disable() async throws {}

    func uninstall() async throws -> NetworkExtensionUninstallOutcome {
        .uninstalled
    }

    func currentState() async -> NetworkExtensionControlState {
        .inactive
    }

    func providerRuntimeStatus() async throws -> TransparentProxyProviderStatus {
        providerStatusRequestCount += 1
        guard !statuses.isEmpty else { throw SystemProxyError.preferencesUnavailable }
        return statuses.removeFirst()
    }

    func appRoutingActivity(
        after cursor: UInt64,
        limit: Int
    ) async throws -> AppRoutingActivityBatch {
        AppRoutingActivityBatch(
            activities: [],
            nextCursor: cursor,
            droppedBeforeSequence: nil,
            hasMore: false
        )
    }

    func clearAppRoutingActivity() async throws {}
}
