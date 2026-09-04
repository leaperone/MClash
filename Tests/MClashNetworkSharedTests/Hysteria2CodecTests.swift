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
        if !headers.contains(where: { $0.0 == ":method" && $0.1 == "POST" }) {
            Issue.record("Hysteria2 authentication is missing the POST method")
        }
        if !headers.contains(where: { $0.0 == ":path" && $0.1 == "/auth" }) {
            Issue.record("Hysteria2 authentication is missing the /auth path")
        }
        if !headers.contains(where: { $0.0 == "Hysteria-Auth" && $0.1 == "secret" }) {
            Issue.record("Hysteria2 authentication is missing its credential header")
        }
        if !headers.contains(where: { $0.0 == "Hysteria-CC-RX" && $0.1 == "1000000" }) {
            Issue.record("Hysteria2 authentication is missing its receive-rate header")
        }
        let frame = try Hysteria2Codec.encodeAuthHeadersFrame(password: "secret")
        #expect(try HTTP3FrameCodec.decode(frame).type == .headers)
    }

    @Test("Authentication frame round-trips the complete ordered field section")
    func authFrameRoundTrip() throws {
        let frame = try Hysteria2Codec.encodeAuthHeadersFrame(
            password: "secret",
            receiveRate: 42,
            padding: "p"
        )
        let decoded = try HTTP3FrameCodec.decode(frame)
        #expect(decoded.type == .headers)
        let fields = try QPACKDecoder.decodeLiteralFields(decoded.payload)
        #expect(fields.map(\.0) == [
            ":method", ":path", ":authority", "Hysteria-Auth",
            "Hysteria-CC-RX", "Hysteria-Padding",
        ])
        #expect(fields.map(\.1) == [
            "POST", "/auth", "hysteria", "secret", "42", "p",
        ])
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
        #expect(data[8] == 0x0e)
        #expect(String(decoding: data[9..<23], as: UTF8.self) == "example.com:53")
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

    @Test("TCP response rejects trailing bytes and accepts large varint fields")
    func tcpResponseBoundaries() throws {
        // The response framing is status, varint message length, message,
        // varint padding length, padding. Trailing bytes are not another
        // response and must not be silently accepted.
        #expect(throws: Hysteria2CodecError.invalidVarint) {
            try Hysteria2Codec.decodeTCPResponse(Data([0x00, 0x00, 0x00, 0x01]))
        }

        let message = Data(repeating: 0x61, count: 128)
        // QUIC varint 128 is encoded as 0x40 0x80.
        let encoded = Data([0x00, 0x40, 0x80]) + message + Data([0x00])
        let response = try Hysteria2Codec.decodeTCPResponse(encoded)
        #expect(response.accepted)
        #expect(response.message.utf8.count == message.count)
    }

    @Test("Validates Hysteria2 authentication response status and capabilities")
    func authResponse() throws {
        let response = try Hysteria2Codec.decodeAuthResponse(
            statusCode: 233,
            headers: ["Hysteria-UDP": "true", "Hysteria-CC-RX": "1000"]
        )
        #expect(response.udpEnabled)
        #expect(response.receiveRate == 1000)
        #expect(throws: Hysteria2CodecError.serverRejected("HTTP status 200")) {
            try Hysteria2Codec.decodeAuthResponse(
                statusCode: 200,
                headers: ["Hysteria-UDP": "true"]
            )
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
