import Foundation
import MClashNetworkShared
import Testing
@testable import MClashApp

@Suite("Network capture configuration store")
struct NetworkCaptureConfigurationStoreTests {
    @Test("Missing configuration is disabled and fail-open")
    func missingConfigurationIsSafe() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = try NetworkCaptureConfigurationStore(applicationRoot: fixture.root)

        let value = try await store.load()

        #expect(!value.enabled)
        #expect(!value.dnsEnabled)
        #expect(value.failOpen)
        #expect(value.snapshot.revision == 0)
        #expect(value.snapshot.rules.isEmpty)
    }

    @Test("Rule replacement advances revision and persists privately")
    func replacementPersistsPrivateDocument() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = try NetworkCaptureConfigurationStore(applicationRoot: fixture.root)
        let rule = try CaptureRule(
            id: "app-to-mihomo",
            priority: 10,
            sources: [.userID(501)],
            destinations: [.network(try IPNetwork("203.0.113.0/24"))],
            protocols: [.tcp, .udp],
            action: .mihomo(.profileRules)
        )

        let saved = try await store.replaceRules(
            [rule],
            enabled: true,
            dnsEnabled: true
        )
        let loaded = try await store.load()

        #expect(saved.snapshot.revision == 1)
        #expect(loaded == saved)
        #expect(loaded.snapshot.rules == [rule])

        let layout = NetworkCaptureStorageLayout(applicationRoot: fixture.root)
        let attributes = try FileManager.default.attributesOfItem(
            atPath: layout.preferencesURL.path
        )
        let permissions = attributes[.posixPermissions] as? NSNumber
        #expect(permissions?.intValue == 0o600)
    }

    @Test("Saving a stale revision is rejected without replacing current rules")
    func staleRevisionIsRejected() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = try NetworkCaptureConfigurationStore(applicationRoot: fixture.root)
        let current = try await store.replaceRules(
            [],
            enabled: true,
            dnsEnabled: false
        )

        await #expect(throws: NetworkCaptureConfigurationStoreError.self) {
            try await store.save(current)
        }
        #expect(try await store.load() == current)
    }

    @Test("Unsupported document schemas fail closed at the host boundary")
    func unsupportedSchemaIsRejected() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = try NetworkCaptureConfigurationStore(applicationRoot: fixture.root)
        let layout = NetworkCaptureStorageLayout(applicationRoot: fixture.root)
        try Data(#"{"schemaVersion":99,"preferences":{}}"#.utf8)
            .write(to: layout.preferencesURL)

        await #expect(throws: NetworkCaptureConfigurationStoreError.self) {
            try await store.load()
        }
    }
}

private struct Fixture {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MClash-CaptureStore-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}
