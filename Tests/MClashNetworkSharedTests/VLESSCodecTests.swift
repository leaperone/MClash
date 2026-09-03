import Foundation
import Testing
@testable import MClashNetworkShared

@Suite("VLESS TCP codec")
struct VLESSCodecTests {
    @Test("Encodes a domain TCP request with Xray-compatible framing")
    func encodesDomainRequest() throws {
        let data = try VLESSCodec.encodeTCPRequest(
            uuid: "00000000-0000-0000-0000-000000000001",
            host: "example.com",
            port: 443
        )
        #expect(data[0] == 0x01)
        #expect(data[17] == 0x00) // addons length
        #expect(data[18] == 0x01) // TCP command
        #expect(data[19] == 0x01 && data[20] == 0xbb)
        #expect(data[21] == 0x02)
        #expect(data[22] == UInt8("example.com".utf8.count))
        #expect(String(decoding: data.dropFirst(23), as: UTF8.self) == "example.com")
        let hex = data.map { String(format: "%02x", $0) }.joined()
        #expect(hex.hasPrefix("0100000000000000000000000000000001000101bb020b6578616d706c652e636f6d"))
    }

    @Test("Rejects invalid UUID, host, and port")
    func rejectsInvalidInput() {
        #expect(throws: VLESSCodecError.invalidUUID) {
            try VLESSCodec.encodeTCPRequest(uuid: "invalid", host: "example.com", port: 443)
        }
        #expect(throws: VLESSCodecError.invalidHost) {
            try VLESSCodec.encodeTCPRequest(uuid: "00000000-0000-0000-0000-000000000001", host: "", port: 443)
        }
        #expect(throws: VLESSCodecError.invalidPort) {
            try VLESSCodec.encodeTCPRequest(uuid: "00000000-0000-0000-0000-000000000001", host: "example.com", port: 0)
        }
    }
}
