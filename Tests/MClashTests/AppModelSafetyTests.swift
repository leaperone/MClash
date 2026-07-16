import Foundation
import Testing
@testable import MClashApp

@Suite("App model network safety")
struct AppModelSafetyTests {
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

@MainActor
private struct Fixture {
    let root: URL
    let snapshotURL: URL
    let backend: RestoreBackend
    let model: AppModel

    init(failsRestore: Bool, restoreDelay: TimeInterval = 0) throws {
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
