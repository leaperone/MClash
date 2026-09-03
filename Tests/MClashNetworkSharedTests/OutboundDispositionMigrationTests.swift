import Foundation
import Testing
@testable import MClashNetworkShared

@Suite("Connector-neutral outbound disposition migration")
struct OutboundDispositionMigrationTests {
    @Test
    func newOutboundFactoryUsesCanonicalWireKey() throws {
        let action = CaptureAction.outbound(.group("AI"))
        let disposition = FlowTrafficDisposition.outbound(.global)
        let encoder = JSONEncoder()
        let actionJSON = String(decoding: try encoder.encode(action), as: UTF8.self)
        let dispositionJSON = String(decoding: try encoder.encode(disposition), as: UTF8.self)

        #expect(actionJSON.contains("\"outbound\""))
        #expect(!actionJSON.contains("\"mihomo\""))
        #expect(dispositionJSON.contains("\"outbound\""))
        #expect(!dispositionJSON.contains("\"mihomo\""))
    }

    @Test
    func legacyMihomoWireKeyStillDecodes() throws {
        let encoder = JSONEncoder()
        let actionData = try encoder.encode(CaptureAction.outbound(.group("Pinned")))
        let dispositionData = try encoder.encode(FlowTrafficDisposition.outbound(.profileRules))
        let actionLegacy = try replacingOutboundKey(in: actionData)
        let dispositionLegacy = try replacingOutboundKey(in: dispositionData)

        let action = try JSONDecoder().decode(CaptureAction.self, from: actionLegacy)
        let disposition = try JSONDecoder().decode(FlowTrafficDisposition.self, from: dispositionLegacy)
        #expect(action == .outbound(.group("Pinned")))
        #expect(disposition == .outbound(.profileRules))
    }

    @Test
    func directAndRejectRemainCodable() throws {
        let values: [CaptureAction] = [.direct, .reject]
        let dispositions: [FlowTrafficDisposition] = [.direct, .reject, .failOpen]
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        for value in values {
            #expect(try decoder.decode(CaptureAction.self, from: encoder.encode(value)) == value)
        }
        for value in dispositions {
            #expect(try decoder.decode(FlowTrafficDisposition.self, from: encoder.encode(value)) == value)
        }
    }

    private func replacingOutboundKey(in data: Data) throws -> Data {
        let value = String(decoding: data, as: UTF8.self)
        guard value.contains("\"outbound\"") else {
            throw NSError(domain: "OutboundDispositionMigrationTests", code: 1)
        }
        return Data(value.replacingOccurrences(of: "\"outbound\"", with: "\"mihomo\"").utf8)
    }
}
