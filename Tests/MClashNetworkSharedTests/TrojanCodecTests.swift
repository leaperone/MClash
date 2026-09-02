import Foundation
import Testing
@testable import MClashNetworkShared

@Suite("Trojan TCP codec")
struct TrojanCodecTests {
    @Test("Emits SHA-224 password prefix and SOCKS5 CONNECT request")
    func encodesHandshake() throws {
        let data = try TrojanCodec.encodeTCPRequest(
            password: "password",
            host: "example.com",
            port: 443
        )
        let prefix = String(decoding: data.prefix(58), as: UTF8.self)
        #expect(prefix == "d63dc919e201d7bc4c825630d2cf25fdc93d4b2f0d46706d29038d01\r\n")
        #expect(data.dropFirst(58).first == 0x05)
        #expect(data.dropFirst(58).dropFirst(1).first == 0x01)
    }

    @Test("Rejects empty password and invalid target")
    func rejectsInvalidInput() {
        #expect(throws: TrojanCodecError.invalidPassword) {
            try TrojanCodec.encodeTCPRequest(password: "", host: "example.com", port: 443)
        }
        #expect(throws: TrojanCodecError.invalidTarget) {
            try TrojanCodec.encodeTCPRequest(password: "secret", host: "", port: 443)
        }
    }
}
