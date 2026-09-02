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
        let frame = try Hysteria2Codec.encodeAuthHeadersFrame(password: "secret")
        #expect(try HTTP3FrameCodec.decode(frame).type == .headers)
    }

    @Test("Encodes TCP request ID and address length as QUIC varints")
    func tcpRequest() throws {
        let data = try Hysteria2Codec.encodeTCPRequest(host: "example.com", port: 443)
        #expect(data.prefix(2).elementsEqual([0x44, 0x01]))
        #expect(data[2] == 0x0f)
        #expect(String(decoding: data[3..<18], as: UTF8.self) == "example.com:443")
        #expect(data[18] == 0x00)
    }

    @Test("Encodes UDP session and fragmentation fields")
    func udpMessage() throws {
        let data = try Hysteria2Codec.encodeUDPMessage(
            sessionID: 0x01020304,
            packetID: 0x0506,
            fragmentID: 1,
            fragmentCount: 2,
            host: "example.com",
            port: 53,
            payload: Data([0xde, 0xad])
        )
        #expect(Array(data.prefix(8)) == [1, 2, 3, 4, 5, 6, 1, 2])
        #expect(data[8] == 0x0f)
        #expect(String(decoding: data[9..<24], as: UTF8.self) == "example.com:53")
        #expect(Array(data.suffix(2)) == [0xde, 0xad])
        let decoded = try Hysteria2Codec.decodeUDPMessage(data)
        #expect(decoded.sessionID == 0x01020304)
        #expect(decoded.packetID == 0x0506)
        #expect(decoded.fragmentID == 1 && decoded.fragmentCount == 2)
        #expect(decoded.host == "example.com" && decoded.port == 53)
        #expect(decoded.payload == Data([0xde, 0xad]))
    }

    @Test("Brackets IPv6 UDP targets for unambiguous port parsing")
    func ipv6UDPMessage() throws {
        let encoded = try Hysteria2Codec.encodeUDPMessage(
            sessionID: 1, packetID: 1, host: "2001:db8::1", port: 53, payload: Data([7])
        )
        let decoded = try Hysteria2Codec.decodeUDPMessage(encoded)
        #expect(decoded.host == "2001:db8::1")
        #expect(decoded.port == 53)
    }

    @Test("Decodes successful and rejected TCP responses")
    func tcpResponse() throws {
        let accepted = try Hysteria2Codec.decodeTCPResponse(Data([0x00, 0x02, 0x6f, 0x6b, 0x00]))
        #expect(accepted.accepted)
        #expect(accepted.message == "ok")
        #expect(throws: Hysteria2CodecError.serverRejected("denied")) {
            try Hysteria2Codec.decodeTCPResponse(Data([0x01, 0x06]) + Data("denied".utf8) + Data([0x00]))
        }
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
