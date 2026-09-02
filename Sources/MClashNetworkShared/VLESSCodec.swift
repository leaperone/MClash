import Darwin
import Foundation

public enum VLESSCodecError: Error, Equatable, Sendable {
    case invalidUUID
    case invalidHost
    case invalidPort
    case messageTooLarge
}

/// Minimal VLESS TCP request codec. It intentionally contains no routing or
/// socket code; connector implementations can validate the wire bytes against
/// Xray/Mihomo golden vectors before using it in production.
public enum VLESSCodec: Sendable {
    public static let version: UInt8 = 0x01
    private static let tcpCommand: UInt8 = 0x01
    private static let maximumHostBytes = 255

    public static func encodeTCPRequest(
        uuid: String,
        host: String,
        port: UInt16
    ) throws -> Data {
        guard let parsedUUID = UUID(uuidString: uuid) else {
            throw VLESSCodecError.invalidUUID
        }
        guard port > 0 else { throw VLESSCodecError.invalidPort }
        let normalizedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedHost.isEmpty else { throw VLESSCodecError.invalidHost }
        let address: Data
        if let ipv4 = IPv4AddressBytes(normalizedHost) {
            address = Data([0x01]) + ipv4
        } else if let ipv6 = IPv6AddressBytes(normalizedHost) {
            address = Data([0x03]) + ipv6
        } else {
            let bytes = Array(normalizedHost.utf8)
            guard bytes.count <= maximumHostBytes else { throw VLESSCodecError.invalidHost }
            address = Data([0x02, UInt8(bytes.count)]) + Data(bytes)
        }
        var result = Data([version])
        result.append(contentsOf: withUnsafeBytes(of: parsedUUID.uuid) { Data($0) })
        result.append(contentsOf: [0x00, tcpCommand]) // addons length and TCP command
        result.append(contentsOf: [UInt8(port >> 8), UInt8(port & 0xff)])
        result.append(address)
        guard result.count <= 512 else { throw VLESSCodecError.messageTooLarge }
        return result
    }

    private static func IPv4AddressBytes(_ host: String) -> Data? {
        var address = in_addr()
        return host.withCString { inet_pton(AF_INET, $0, &address) == 1
            ? Data(bytes: &address, count: MemoryLayout<in_addr>.size)
            : nil }
    }

    private static func IPv6AddressBytes(_ host: String) -> Data? {
        var address = in6_addr()
        return host.withCString { inet_pton(AF_INET6, $0, &address) == 1
            ? Data(bytes: &address, count: MemoryLayout<in6_addr>.size)
            : nil }
    }
}
