import Foundation
import Testing
@testable import MClashNetworkShared

@Suite("Shadowsocks SIP002 AEAD codec")
struct ShadowsocksCodecTests {
    @Test("Round trips all supported AEAD methods with fragmented input")
    func roundTripsMethods() throws {
        for method in ShadowsocksAEADMethod.allCases {
            let salt = Data(repeating: 0x42, count: method == .aes128GCM ? 16 : 32)
            var encoder = try ShadowsocksAEADStreamEncoder(
                methodName: method.rawValue,
                password: "correct horse battery staple",
                salt: salt
            )
            let first = try encoder.encode(Data("hello".utf8))
            let second = try encoder.encode(Data(repeating: 0x7f, count: 257))
            var decoder = try ShadowsocksAEADStreamDecoder(
                methodName: method.rawValue,
                password: "correct horse battery staple"
            )
            var decoded = [Data]()
            for byte in (first + second) {
                decoded += try decoder.append(Data([byte]))
            }
            #expect(decoded == [Data("hello".utf8), Data(repeating: 0x7f, count: 257)])
        }
    }

    @Test("Rejects unsupported methods, empty credentials and oversized frames")
    func rejectsInvalidInput() throws {
        #expect(throws: ShadowsocksCodecError.unsupportedMethod("rc4-md5")) {
            try ShadowsocksAEADStreamEncoder(methodName: "rc4-md5", password: "secret")
        }
        #expect(throws: ShadowsocksCodecError.emptyPassword) {
            try ShadowsocksAEADStreamEncoder(methodName: "aes-256-gcm", password: "")
        }
        #expect(throws: ShadowsocksCodecError.invalidSaltLength(4)) {
            try ShadowsocksAEADStreamEncoder(
                methodName: "aes-128-gcm",
                password: "secret",
                salt: Data(repeating: 0, count: 4)
            )
        }
        var encoder = try ShadowsocksAEADStreamEncoder(methodName: "aes-128-gcm", password: "secret")
        #expect(throws: ShadowsocksCodecError.frameTooLarge(16_384)) {
            try encoder.encode(Data(repeating: 0, count: 16_384))
        }
    }

    @Test("Detects tampered authentication tag")
    func detectsTampering() throws {
        var encoder = try ShadowsocksAEADStreamEncoder(
            methodName: "chacha20-ietf-poly1305",
            password: "secret",
            salt: Data(repeating: 3, count: 32)
        )
        var encoded = try encoder.encode(Data("payload".utf8))
        encoded[encoded.index(before: encoded.endIndex)] ^= 0x01
        var decoder = try ShadowsocksAEADStreamDecoder(
            methodName: "chacha20-ietf-poly1305",
            password: "secret"
        )
        #expect(throws: ShadowsocksCodecError.authenticationFailed) {
            _ = try decoder.append(encoded)
        }
    }
}
