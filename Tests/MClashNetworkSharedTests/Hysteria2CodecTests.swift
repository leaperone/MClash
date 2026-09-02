import Foundation
import Testing
@testable import MClashNetworkShared

@Suite("Hysteria2 protocol codec")
struct Hysteria2CodecTests {
    @Test("Builds authentication headers from the protocol contract")
    func authHeaders() throws {
        let headers = try Hysteria2Codec.authHeaders(
            password: "secret",
            receiveRate: 1_000_000,
            padding: "pad"
        )
        #expect(headers.contains { $0.0 == ":method" && $0.1 == "POST" })
        #expect(headers.contains { $0.0 == ":path" && $0.1 == "/auth" })
        #expect(headers.contains { $0.0 == "Hysteria-Auth" && $0.1 == "secret" })
        #expect(headers.contains { $0.0 == "Hysteria-CC-RX" && $0.1 == "1000000" })
    }

    @Test("Encodes TCP request ID and address length as QUIC varints")
    func tcpRequest() throws {
        let data = try Hysteria2Codec.encodeTCPRequest(host: "example.com", port: 443)
        #expect(data.prefix(2).elementsEqual([0x44, 0x01]))
        #expect(data[2] == 0x0f)
        #expect(String(decoding: data[3..<18], as: UTF8.self) == "example.com:443")
        #expect(data[18] == 0x00)
    }

    @Test("Rejects empty credentials, targets, and oversized padding")
    func rejectsInvalidInput() {
        #expect(throws: Hysteria2CodecError.invalidAuth) {
            try Hysteria2Codec.authHeaders(password: "")
        }
        #expect(throws: Hysteria2CodecError.invalidAddress) {
            try Hysteria2Codec.encodeTCPRequest(host: "", port: 443)
        }
        #expect(throws: Hysteria2CodecError.oversized) {
            try Hysteria2Codec.authHeaders(password: "secret", padding: String(repeating: "x", count: 4097))
        }
    }
}
