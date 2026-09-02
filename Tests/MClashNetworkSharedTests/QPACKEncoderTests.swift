import Foundation
import Testing
@testable import MClashNetworkShared

@Suite("QPACK literal encoder")
struct QPACKEncoderTests {
    @Test("Encodes deterministic literal pseudo and custom headers")
    func encodesLiteralFields() throws {
        let data = try QPACKEncoder.encodeLiteralFields([
            (":method", "POST"),
            (":path", "/auth"),
            ("Hysteria-Auth", "secret"),
        ])
        #expect(data.prefix(2).elementsEqual([0x00, 0x00]))
        #expect(data.contains(0x20 | 7)) // :method name length
        #expect(String(decoding: data, as: UTF8.self).contains(":method"))
        #expect(String(decoding: data, as: UTF8.self).contains("Hysteria-Auth"))
    }

    @Test("Rejects empty names and oversized values")
    func rejectsInvalidFields() {
        #expect(throws: QPACKEncoderError.invalidFieldName) {
            try QPACKEncoder.encodeLiteralFields([("", "value")])
        }
        #expect(throws: QPACKEncoderError.invalidFieldValue) {
            try QPACKEncoder.encodeLiteralFields([("name", String(repeating: "x", count: 65_536))])
        }
    }
}
