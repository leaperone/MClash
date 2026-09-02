import CommonCrypto
import Foundation

public enum TrojanCodecError: Error, Equatable, Sendable {
    case invalidPassword
    case invalidTarget
}

/// Trojan TCP client handshake codec. The transport (usually TLS) is owned by
/// the connector; this type only emits the authenticated SOCKS5 request bytes.
public enum TrojanCodec: Sendable {
    public static func encodeTCPRequest(
        password: String,
        host: String,
        port: UInt16
    ) throws -> Data {
        let trimmedPassword = password.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPassword.isEmpty else { throw TrojanCodecError.invalidPassword }
        let normalizedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedHost.isEmpty, port > 0 else { throw TrojanCodecError.invalidTarget }
        var digestBytes = [UInt8](repeating: 0, count: Int(CC_SHA224_DIGEST_LENGTH))
        Data(trimmedPassword.utf8).withUnsafeBytes { bytes in
            _ = CC_SHA224(bytes.baseAddress, CC_LONG(bytes.count), &digestBytes)
        }
        let digest = digestBytes.map { String(format: "%02x", $0) }.joined()
        let endpoint = try SOCKS5Endpoint(
            address: SOCKS5Address(domain: normalizedHost),
            port: port
        )
        return Data(digest.utf8) + Data("\r\n".utf8)
            + (try SOCKS5Codec.encodeCommandRequest(
                try SOCKS5CommandRequest(command: .connect, endpoint: endpoint)
            ))
    }
}
