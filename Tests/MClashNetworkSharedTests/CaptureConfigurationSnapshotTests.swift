import Foundation
@testable import MClashNetworkShared
import Testing

@Suite("Capture configuration snapshots")
struct CaptureConfigurationSnapshotTests {
    @Test
    func testSnapshotRoundTripsWithVersionAndRevision() throws {
        let rule = try CaptureRule(
            id: "proxy-web",
            priority: 20,
            destinations: [.network(try IPNetwork("2001:db8::/32"))],
            protocols: [.tcp, .udp],
            portRanges: [try PortRange(lowerBound: 443, upperBound: 8443)],
            action: .mihomo(.group("Auto")),
            unavailableFallback: .reject
        )
        let snapshot = try CaptureConfigurationSnapshot(
            revision: 9,
            generationID: UUID(uuidString: "00000000-0000-0000-0000-000000000009")!,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            rules: [rule]
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(snapshot)
        let decoded = try JSONDecoder().decode(CaptureConfigurationSnapshot.self, from: data)

        #expect(decoded == snapshot)
        #expect(decoded.schemaVersion == CaptureConfigurationSnapshot.currentSchemaVersion)
        #expect(decoded.revision == 9)
    }

    @Test
    func testUnsupportedSchemaVersionIsRejected() throws {
        #expect(throws: NetworkRuleValidationError.unsupportedSchemaVersion(99)) {
            try CaptureConfigurationSnapshot(schemaVersion: 99, revision: 1, rules: [])
        }
    }

    @Test
    func testDuplicateRuleIdentifiersAreRejected() throws {
        let first = try CaptureRule(id: "same", priority: 1, action: .direct)
        let second = try CaptureRule(id: "same", priority: 2, action: .reject)
        #expect(throws: NetworkRuleValidationError.duplicateRuleIdentifier("same")) {
            try CaptureConfigurationSnapshot(revision: 1, rules: [first, second])
        }
    }

    @Test
    func testEmptyRuleIdentifierAndMihomoGroupAreRejected() {
        #expect(throws: NetworkRuleValidationError.invalidRuleIdentifier("  ")) {
            try CaptureRule(id: "  ", priority: 1, action: .direct)
        }
        #expect(throws: NetworkRuleValidationError.invalidMihomoGroup("  ")) {
            try CaptureRule(id: "group", priority: 1, action: .mihomo(.group("  ")))
        }
    }

    @Test
    func testInvalidDecodedSnapshotIsRejected() throws {
        let snapshot = try CaptureConfigurationSnapshot(revision: 1, rules: [])
        let encoded = try JSONEncoder().encode(snapshot)
        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object["schemaVersion"] = 42
        let corrupted = try JSONSerialization.data(withJSONObject: object)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(CaptureConfigurationSnapshot.self, from: corrupted)
        }
    }
}
