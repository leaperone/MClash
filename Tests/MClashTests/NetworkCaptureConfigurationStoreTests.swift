import Foundation
import MClashNetworkShared
import Testing
@testable import MClashApp

@Suite("Network capture configuration store")
struct NetworkCaptureConfigurationStoreTests {
    @Test("Missing configuration enables fail-open App Routing by default")
    func missingConfigurationUsesProductDefaults() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = try NetworkCaptureConfigurationStore(applicationRoot: fixture.root)

        let value = try await store.load()

        #expect(value.enabled)
        #expect(value.dnsEnabled)
        #expect(value.failOpen)
        #expect(value.snapshot.revision == 1)
        #expect(value.snapshot.rules.isEmpty)
    }

    @Test("Version 1 settings migrate DNS to the coupled default")
    func legacyIndependentDNSSettingMigratesToEnabled() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = try NetworkCaptureConfigurationStore(applicationRoot: fixture.root)
        let snapshot = try CaptureConfigurationSnapshot(revision: 7, rules: [])
        let legacyPreferences = try NetworkCapturePreferences(
            enabled: true,
            dnsEnabled: false,
            snapshot: snapshot
        )
        let document = LegacyDocument(
            schemaVersion: 1,
            preferences: legacyPreferences
        )
        let layout = NetworkCaptureStorageLayout(applicationRoot: fixture.root)
        try JSONEncoder().encode(document).write(to: layout.preferencesURL)

        let migrated = try await store.load()

        #expect(migrated.enabled)
        #expect(migrated.dnsEnabled)
        #expect(migrated.snapshot.revision == 7)
    }

    @Test("Current settings preserve an explicit advanced DNS opt-out")
    func currentAdvancedDNSOptOutPersists() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = try NetworkCaptureConfigurationStore(applicationRoot: fixture.root)

        let saved = try await store.replaceRules(
            [],
            enabled: false,
            dnsEnabled: false
        )
        let loaded = try await store.load()

        #expect(!saved.dnsEnabled)
        #expect(loaded == saved)
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

        #expect(saved.snapshot.revision == 2)
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

private struct LegacyDocument: Encodable {
    let schemaVersion: Int
    let preferences: NetworkCapturePreferences
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
