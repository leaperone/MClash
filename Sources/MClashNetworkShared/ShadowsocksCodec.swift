import CryptoKit
import Foundation

/// AEAD methods defined by the Shadowsocks SIP002 specification.
///
/// The transport is deliberately kept separate from this codec: a connector
/// owns the TCP socket while this type owns the salt, subkey, nonce and frame
/// boundaries.  This makes it impossible for a caller to accidentally send
/// plaintext bytes on a native Shadowsocks route.
public enum ShadowsocksAEADMethod: String, CaseIterable, Hashable, Sendable {
    case aes128GCM = "aes-128-gcm"
    case aes256GCM = "aes-256-gcm"
    case chacha20IETFPoly1305 = "chacha20-ietf-poly1305"

    var keyLength: Int {
        switch self {
        case .aes128GCM: 16
        case .aes256GCM, .chacha20IETFPoly1305: 32
        }
    }
}

public enum ShadowsocksCodecError: Error, Equatable, Sendable {
    case unsupportedMethod(String)
    case emptyPassword
    case invalidSaltLength(Int)
    case invalidPayloadLength(Int)
    case frameTooLarge(Int)
    case authenticationFailed
    case inputTooLarge(Int)
}

extension ShadowsocksCodecError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case let .unsupportedMethod(method): "Unsupported Shadowsocks AEAD method: \(method)"
        case .emptyPassword: "Shadowsocks password must not be empty"
        case let .invalidSaltLength(length): "Invalid Shadowsocks salt length: \(length)"
        case let .invalidPayloadLength(length): "Invalid Shadowsocks payload length: \(length)"
        case let .frameTooLarge(length): "Shadowsocks payload exceeds the 16383-byte frame limit: \(length)"
        case .authenticationFailed: "Shadowsocks AEAD authentication failed"
        case let .inputTooLarge(length): "Shadowsocks decoder input exceeds the safety limit: \(length)"
        }
    }
}

/// SIP002 Shadowsocks AEAD stream codec.
///
/// Each stream starts with a random salt.  Every frame is
/// `AEAD(2-byte big-endian length)` followed by `AEAD(payload)`, with a
/// monotonically increasing 12-byte little-endian nonce for each operation.
/// The password is converted to the legacy Shadowsocks master key using
/// EVP_BytesToKey(MD5), then expanded with HKDF-SHA1 as required by SIP002.
public struct ShadowsocksAEADStreamEncoder: Sendable {
    public let method: ShadowsocksAEADMethod
    public let salt: Data
    private let key: SymmetricKey
    private var nonceCounter: UInt64 = 0
    private var saltEmitted = false

    public init(
        methodName: String,
        password: String,
        salt: Data? = nil
    ) throws {
        guard let method = ShadowsocksAEADMethod(rawValue: methodName.lowercased()) else {
            throw ShadowsocksCodecError.unsupportedMethod(methodName)
        }
        guard !password.isEmpty else { throw ShadowsocksCodecError.emptyPassword }
        let selectedSalt = salt ?? Self.randomSalt(length: method.keyLength)
        guard selectedSalt.count == method.keyLength else {
            throw ShadowsocksCodecError.invalidSaltLength(selectedSalt.count)
        }
        self.method = method
        self.salt = selectedSalt
        let master = Self.evpBytesToKey(password: Data(password.utf8), length: method.keyLength)
        self.key = Self.subkey(master: master, salt: selectedSalt, length: method.keyLength)
    }

    public mutating func encode(_ payload: Data) throws -> Data {
        guard payload.count <= 0x3FFF else { throw ShadowsocksCodecError.frameTooLarge(payload.count) }
        var length = Data([UInt8(payload.count >> 8), UInt8(payload.count & 0xff)])
        length = try seal(length)
        let body = try seal(payload)
        if saltEmitted {
            return length + body
        }
        saltEmitted = true
        return salt + length + body
    }

    private mutating func seal(_ plaintext: Data) throws -> Data {
        let sealed: Data
        do {
            let box: AES.GCM.SealedBox
            switch method {
            case .aes128GCM, .aes256GCM:
                box = try AES.GCM.seal(plaintext, using: key, nonce: Self.nonce(nonceCounter))
                sealed = box.ciphertext + box.tag
            case .chacha20IETFPoly1305:
                let box = try ChaChaPoly.seal(plaintext, using: key, nonce: Self.chachaNonce(nonceCounter))
                sealed = box.ciphertext + box.tag
            }
        } catch {
            throw ShadowsocksCodecError.authenticationFailed
        }
        nonceCounter &+= 1
        return sealed
    }

    private static func randomSalt(length: Int) -> Data {
        var generator = SystemRandomNumberGenerator()
        let bytes = (0..<length).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
        return Data(bytes)
    }

    static func nonce(_ value: UInt64) -> AES.GCM.Nonce {
        var bytes = [UInt8](repeating: 0, count: 12)
        for index in 0..<8 { bytes[index] = UInt8((value >> (index * 8)) & 0xff) }
        return try! AES.GCM.Nonce(data: bytes)
    }

    static func chachaNonce(_ value: UInt64) -> ChaChaPoly.Nonce {
        var bytes = [UInt8](repeating: 0, count: 12)
        for index in 0..<8 { bytes[index] = UInt8((value >> (index * 8)) & 0xff) }
        return try! ChaChaPoly.Nonce(data: bytes)
    }

    static func evpBytesToKey(password: Data, length: Int) -> Data {
        var result = Data()
        var previous = Data()
        while result.count < length {
            var input = Data()
            input.append(previous)
            input.append(password)
            previous = Data(Insecure.MD5.hash(data: input))
            result.append(previous)
        }
        return result.prefix(length)
    }

    static func subkey(master: Data, salt: Data, length: Int) -> SymmetricKey {
        let output = HKDF<Insecure.SHA1>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: master),
            salt: salt,
            info: Data("ss-subkey".utf8),
            outputByteCount: length
        )
        return output
    }
}

public struct ShadowsocksAEADStreamDecoder: Sendable {
    public let method: ShadowsocksAEADMethod
    private var key: SymmetricKey
    private var buffer = Data()
    private var saltRead = false
    private var expectedPayloadLength: Int?
    private var nonceCounter: UInt64 = 0
    private let saltLength: Int

    public init(methodName: String, password: String) throws {
        guard let method = ShadowsocksAEADMethod(rawValue: methodName.lowercased()) else {
            throw ShadowsocksCodecError.unsupportedMethod(methodName)
        }
        guard !password.isEmpty else { throw ShadowsocksCodecError.emptyPassword }
        self.method = method
        self.saltLength = method.keyLength
        // Key is replaced after the salt arrives; this placeholder never gets
        // used before saltRead becomes true.
        self.key = SymmetricKey(size: method == .aes128GCM ? .bits128 : .bits256)
        self.password = Data(password.utf8)
    }

    private let password: Data

    public mutating func append(_ input: Data) throws -> [Data] {
        buffer.append(input)
        guard buffer.count <= 2_000_000 else { throw ShadowsocksCodecError.inputTooLarge(buffer.count) }
        var output = [Data]()
        while true {
            if !saltRead {
                guard buffer.count >= saltLength else { break }
                let salt = buffer.prefix(saltLength)
                buffer.removeFirst(saltLength)
                key = ShadowsocksAEADStreamEncoder.subkey(
                    master: ShadowsocksAEADStreamEncoder.evpBytesToKey(password: password, length: method.keyLength),
                    salt: salt,
                    length: method.keyLength
                )
                saltRead = true
            }
            if expectedPayloadLength == nil {
                guard buffer.count >= 2 + 16 else { break }
                let encrypted = buffer.prefix(18)
                buffer.removeFirst(18)
                let plain = try open(encrypted)
                guard plain.count == 2 else { throw ShadowsocksCodecError.authenticationFailed }
                let length = Int(plain[plain.startIndex]) << 8 | Int(plain[plain.index(after: plain.startIndex)])
                guard length <= 0x3FFF else { throw ShadowsocksCodecError.invalidPayloadLength(length) }
                expectedPayloadLength = length
            }
            guard let length = expectedPayloadLength else { continue }
            guard buffer.count >= length + 16 else { break }
            let encrypted = buffer.prefix(length + 16)
            buffer.removeFirst(length + 16)
            let plain = try open(encrypted)
            guard plain.count == length else { throw ShadowsocksCodecError.authenticationFailed }
            output.append(plain)
            expectedPayloadLength = nil
        }
        return output
    }

    private mutating func open(_ encrypted: Data) throws -> Data {
        guard encrypted.count >= 16 else { throw ShadowsocksCodecError.authenticationFailed }
        let ciphertext = encrypted.dropLast(16)
        let tag = encrypted.suffix(16)
        do {
            let plain: Data
            switch method {
            case .aes128GCM, .aes256GCM:
                let box = try AES.GCM.SealedBox(nonce: ShadowsocksAEADStreamEncoder.nonce(nonceCounter), ciphertext: ciphertext, tag: tag)
                plain = try AES.GCM.open(box, using: key)
            case .chacha20IETFPoly1305:
                let box = try ChaChaPoly.SealedBox(nonce: ShadowsocksAEADStreamEncoder.chachaNonce(nonceCounter), ciphertext: ciphertext, tag: tag)
                plain = try ChaChaPoly.open(box, using: key)
            }
            nonceCounter &+= 1
            return plain
        } catch {
            throw ShadowsocksCodecError.authenticationFailed
        }
    }
}
