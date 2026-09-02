import Foundation

public enum Hysteria2CodecError: Error, Equatable, Sendable {
    case invalidAuth
    case invalidAddress
    case invalidVarint
    case oversized
}

/// Hysteria2 HTTP/3 authentication and proxy request wire helpers. HTTP/3 and
/// QUIC transport are supplied by the connector; this type only emits the
/// protocol payloads defined by PROTOCOL.md.
public enum Hysteria2Codec: Sendable {
    public static func authHeaders(
        password: String,
        receiveRate: UInt64 = 0,
        padding: String = ""
    ) throws -> [(String, String)] {
        let value = password.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.utf8.count <= 1024 else {
            throw Hysteria2CodecError.invalidAuth
        }
        guard padding.utf8.count <= 4096 else { throw Hysteria2CodecError.oversized }
        return [
            (":method", "POST"),
            (":path", "/auth"),
            (":authority", "hysteria"),
            ("Hysteria-Auth", value),
            ("Hysteria-CC-RX", String(receiveRate)),
        ] + (padding.isEmpty ? [] : [("Hysteria-Padding", padding)])
    }

    public static func encodeTCPRequest(host: String, port: UInt16, padding: Data = Data()) throws -> Data {
        let address = "\(host):\(port)"
        guard !host.isEmpty, port > 0, address.utf8.count <= 1024 else {
            throw Hysteria2CodecError.invalidAddress
        }
        guard padding.count <= 4096 else { throw Hysteria2CodecError.oversized }
        var result = encodeVarint(0x401) // QUIC varint TCPRequest ID
        result.append(encodeVarint(UInt64(address.utf8.count)))
        result.append(contentsOf: address.utf8)
        result.append(encodeVarint(UInt64(padding.count)))
        result.append(padding)
        return result
    }

    public static func encodeUDPMessage(
        sessionID: UInt32,
        packetID: UInt16,
        fragmentID: UInt8 = 0,
        fragmentCount: UInt8 = 1,
        host: String,
        port: UInt16,
        payload: Data
    ) throws -> Data {
        let address = "\(host):\(port)"
        guard !host.isEmpty, port > 0, address.utf8.count <= 1024,
              fragmentCount > 0, fragmentID < fragmentCount else {
            throw Hysteria2CodecError.invalidAddress
        }
        guard payload.count <= 65_535 else { throw Hysteria2CodecError.oversized }
        var result = Data([
            UInt8(sessionID >> 24), UInt8(sessionID >> 16), UInt8(sessionID >> 8), UInt8(sessionID),
            UInt8(packetID >> 8), UInt8(packetID), fragmentID, fragmentCount,
        ])
        result.append(encodeVarint(UInt64(address.utf8.count)))
        result.append(contentsOf: address.utf8)
        result.append(payload)
        return result
    }

    private static func encodeVarint(_ value: UInt64) -> Data {
        if value < (1 << 6) { return Data([UInt8(value)]) }
        if value < (1 << 14) { let v = UInt16(value) | 0x4000; return Data([UInt8(v >> 8), UInt8(v)]) }
        if value < (1 << 30) { let v = UInt32(value) | 0x80000000; return Data([UInt8(v >> 24), UInt8(v >> 16), UInt8(v >> 8), UInt8(v)]) }
        let v = value | 0xc000000000000000
        return Data((0..<8).reversed().map { UInt8(v >> (UInt64($0) * 8)) })
    }
}
