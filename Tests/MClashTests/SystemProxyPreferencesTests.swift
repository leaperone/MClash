import Foundation
import Testing
@testable import MClashApp

@Suite("System proxy preferences")
struct SystemProxyPreferencesTests {
    @Test("Effective bypass list includes safe defaults and deduplicates custom entries")
    func effectiveBypassList() throws {
        let preferences = SystemProxyPreferences(
            customBypassDomains: [" Example.com ", "example.COM", "corp.internal"],
            bypassPrivateNetworks: false,
            guardEnabled: true,
            guardIntervalSeconds: 20
        )

        let validated = try preferences.validated()
        #expect(validated.effectiveBypassDomains.prefix(4) == ["localhost", "127.0.0.1", "::1", "*.local"])
        #expect(validated.effectiveBypassDomains.suffix(2) == ["Example.com", "corp.internal"])
    }

    @Test("Settings persist atomically and reject unsafe values")
    func persistenceAndValidation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "MClashSystemProxyPreferences-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let layout = ProfileDirectoryLayout(rootDirectory: root)
        let store = try SystemProxyPreferencesStore(profileLayout: layout)
        let preferences = SystemProxyPreferences(
            customBypassDomains: ["example.internal"],
            bypassPrivateNetworks: false,
            guardEnabled: false,
            guardIntervalSeconds: 30
        )

        try await store.save(preferences)
        #expect(try await store.load() == preferences)
        let settingsURL = await store.settingsURL
        let permissions = try #require(
            FileManager.default.attributesOfItem(atPath: settingsURL.path)[.posixPermissions]
                as? NSNumber
        )
        #expect(permissions.intValue & 0o777 == 0o600)

        #expect(throws: SystemProxyPreferencesError.self) {
            try SystemProxyPreferences(
                customBypassDomains: ["bad\nvalue"]
            ).validated()
        }
        #expect(throws: SystemProxyPreferencesError.self) {
            try SystemProxyPreferences(guardIntervalSeconds: 1).validated()
        }
    }
}
