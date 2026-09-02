import Foundation

public enum Hysteria2CodecError: Error, Equatable, Sendable {
    case invalidAuth
    case invalidAddress
    case invalidVarint
    case oversized
    case serverRejected(String)
}

/// Hysteria2 HTTP/3 authentication and proxy request wire helpers. HTTP/3 and
/// QUIC transport are supplied by the connector; this type only emits the
/// protocol payloads defined by PROTOCOL.md.
public enum Hysteria2Codec: Sendable {
    public struct UDPMessage: Equatable, Sendable {
        public let sessionID: UInt32
        public let packetID: UInt16
        public let fragmentID: UInt8
        public let fragmentCount: UInt8
        public let host: String
        public let port: UInt16
        public let payload: Data
    }
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

    public static func encodeAuthHeadersFrame(
        password: String,
        receiveRate: UInt64 = 0,
        padding: String = ""
    ) throws -> Data {
        let headers = try authHeaders(
            password: password,
            receiveRate: receiveRate,
            padding: padding
        )
        let fieldSection = try QPACKEncoder.encodeLiteralFields(headers)
        return try HTTP3FrameCodec.encode(
            HTTP3Frame(type: .headers, payload: fieldSection)
        )
    }

    public static func encodeTCPRequest(host: String, port: UInt16, padding: Data = Data()) throws -> Data {
        let addressHost = host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
        let address = "\(addressHost):\(port)"
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
        let addressHost = host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
        let address = "\(addressHost):\(port)"
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

    public static func decodeUDPMessage(_ data: Data) throws -> UDPMessage {
        guard data.count >= 9 else { throw Hysteria2CodecError.invalidVarint }
        let sessionID = UInt32(data[0]) << 24 | UInt32(data[1]) << 16
            | UInt32(data[2]) << 8 | UInt32(data[3])
        let packetID = UInt16(data[4]) << 8 | UInt16(data[5])
        let fragmentID = data[6]
        let fragmentCount = data[7]
        guard fragmentCount > 0, fragmentID < fragmentCount else {
            throw Hysteria2CodecError.invalidAddress
        }
        var offset = 8
        let addressLength = try decodeVarint(data, offset: &offset)
        guard addressLength > 0, addressLength <= 1024,
              offset + Int(addressLength) <= data.count else {
            throw Hysteria2CodecError.invalidAddress
        }
        let address = String(decoding: data[offset..<(offset + Int(addressLength))], as: UTF8.self)
        offset += Int(addressLength)
        guard let separator = address.lastIndex(of: ":"),
              let port = UInt16(address[address.index(after: separator)...]),
              port > 0 else { throw Hysteria2CodecError.invalidAddress }
        var host = String(address[..<separator])
        if host.first == "[", host.last == "]" {
            host.removeFirst()
            host.removeLast()
        }
        guard !host.isEmpty else { throw Hysteria2CodecError.invalidAddress }
        return UDPMessage(
            sessionID: sessionID,
            packetID: packetID,
            fragmentID: fragmentID,
            fragmentCount: fragmentCount,
            host: host,
            port: port,
            payload: Data(data[offset...])
        )
    }

    public static func decodeTCPResponse(_ data: Data) throws -> (accepted: Bool, message: String) {
        guard !data.isEmpty else { throw Hysteria2CodecError.invalidVarint }
        let status = data[data.startIndex]
        var offset = 1
        let messageLength = try decodeVarint(data, offset: &offset)
        guard messageLength <= 4096, offset + Int(messageLength) <= data.count else {
            throw Hysteria2CodecError.oversized
        }
        let messageData = data[offset..<(offset + Int(messageLength))]
        offset += Int(messageLength)
        let paddingLength = try decodeVarint(data, offset: &offset)
        guard paddingLength <= 4096, offset + Int(paddingLength) == data.count else {
            throw Hysteria2CodecError.invalidVarint
        }
        let message = String(decoding: messageData, as: UTF8.self)
        guard status == 0 else { throw Hysteria2CodecError.serverRejected(message) }
        return (true, message)
    }

    private static func encodeVarint(_ value: UInt64) -> Data {
        if value < (1 << 6) { return Data([UInt8(value)]) }
        if value < (1 << 14) { let v = UInt16(value) | 0x4000; return Data([UInt8(v >> 8), UInt8(v)]) }
        if value < (1 << 30) { let v = UInt32(value) | 0x80000000; return Data([UInt8(v >> 24), UInt8(v >> 16), UInt8(v >> 8), UInt8(v)]) }
        let v = value | 0xc000000000000000
        return Data((0..<8).reversed().map { UInt8(v >> (UInt64($0) * 8)) })
    }

    private static func decodeVarint(_ data: Data, offset: inout Int) throws -> UInt64 {
        guard offset < data.count else { throw Hysteria2CodecError.invalidVarint }
        let first = data[data.startIndex + offset]
        let prefix = first >> 6
        let length = 1 << Int(prefix)
        guard offset + length <= data.count else { throw Hysteria2CodecError.invalidVarint }
        var value = UInt64(first & 0x3f)
        for index in 1..<length {
            value = (value << 8) | UInt64(data[data.startIndex + offset + index])
        }
        offset += length
        return value
    }
}
