import Foundation

/// The transport options preserved by the node-only importer for a VLESS
/// WebSocket node.  This is deliberately a value type in the shared target so
/// both the compiler and a future native connector consume the same parsed
/// representation rather than each interpreting an opaque JSON string.
public struct VLESSWebSocketOptions: Codable, Equatable, Hashable, Sendable {
    public let path: String
    public let headers: [String: String]

    public init(path: String = "/", headers: [String: String] = [:]) {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        self.path = trimmed.isEmpty ? "/" : (trimmed.hasPrefix("/") ? trimmed : "/" + trimmed)
        self.headers = headers
    }

    /// Reads the common Clash spellings (`ws-opts`, `ws_opts`, and flattened
    /// `ws-path`/`ws-host`). Importers currently store nested maps as JSON in
    /// `OutboundNodeTarget.parameters`, so malformed JSON is rejected instead
    /// of silently selecting a different transport.
    public static func parse(parameters: [String: String]) -> VLESSWebSocketOptions? {
        let normalized = Dictionary(parameters.map {
            ($0.key.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                .replacingOccurrences(of: "_", with: "-"), $0.value)
        }, uniquingKeysWith: { first, _ in first })
        var path: String?
        var headers: [String: String] = [:]
        for key in ["ws-opts", "ws-options"] {
            guard let raw = normalized[key],
                  let data = raw.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data),
                  let map = object as? [String: Any]
            else { continue }
            if let value = map["path"] as? String { path = value }
            if let values = map["headers"] as? [String: String] { headers.merge(values) { _, new in new } }
            if let values = map["headers"] as? [String: Any] {
                for (name, value) in values {
                    if let value = value as? String { headers[name] = value }
                }
            }
        }
        path = path ?? normalized["ws-path"]
        if let host = normalized["ws-host"], !host.isEmpty { headers["Host"] = host }
        guard path != nil || !headers.isEmpty || normalized.keys.contains("ws-opts") || normalized.keys.contains("ws-options") else {
            return nil
        }
        return VLESSWebSocketOptions(path: path ?? "/", headers: headers)
    }
}

public enum VLESSWebSocketTransportDiagnostic: Equatable, Sendable {
    case nativeTransportUnavailable(path: String)

    public var message: String {
        switch self {
        case let .nativeTransportUnavailable(path):
            return "VLESS WebSocket transport requires a two-phase HTTP upgrade on path \(path)."
        }
    }
}

public enum VLESSWebSocketTunnelError: Error, Equatable, Sendable {
    case invalidFrame
    case messageTooLarge
}

/// Stateful RFC 6455 framing for a VLESS byte tunnel. Both the app-owned
/// HTTP/SOCKS entrances and the Network Extension delegate to this exact
/// implementation so masking, bounds and VLESS response stripping cannot
/// drift between ingress paths.
public final class VLESSWebSocketTunnelCodec: @unchecked Sendable {
    public static let maximumPayload = 16 * 1024 * 1024

    private var receiveBuffer = Data()
    private var responseDecoder = VLESSResponseDecoder()
    private let destination: Data

    public init(target: OutboundNodeTarget, destination: SOCKS5Endpoint) throws {
        let uuid = target.parameters["uuid"] ?? ""
        let host = destination.address.domain
            ?? destination.address.ipAddress?.presentation
            ?? ""
        self.destination = try VLESSCodec.encodeTCPRequest(
            uuid: uuid,
            host: host,
            port: destination.port
        )
    }

    public func encodeDestination() throws -> Data {
        try Self.frame(destination, opcode: 0x2, mask: true)
    }

    public func encode(_ payload: Data) throws -> Data {
        try Self.frame(payload, opcode: 0x2, mask: true)
    }

    public func encodeClose() throws -> Data {
        try Self.frame(Data([0x03, 0xE8]), opcode: 0x8, mask: true)
    }

    public func decode(_ input: Data) throws -> [Data] {
        guard input.count <= Self.maximumPayload,
              receiveBuffer.count <= Self.maximumPayload + 10 - input.count else {
            throw VLESSWebSocketTunnelError.messageTooLarge
        }
        receiveBuffer.append(input)
        var output: [Data] = []
        while true {
            guard receiveBuffer.count >= 2 else { break }
            let first = receiveBuffer[receiveBuffer.startIndex]
            let second = receiveBuffer[receiveBuffer.index(after: receiveBuffer.startIndex)]
            let fin = first & 0x80 != 0
            let opcode = first & 0x0f
            let masked = second & 0x80 != 0
            guard first & 0x70 == 0, fin, !masked,
                  opcode == 0x2 || opcode == 0x8 || opcode == 0xA else {
                throw VLESSWebSocketTunnelError.invalidFrame
            }
            var length = Int(second & 0x7f)
            var headerLength = 2
            if length == 126 {
                guard receiveBuffer.count >= 4 else { break }
                let high = receiveBuffer.index(receiveBuffer.startIndex, offsetBy: 2)
                let low = receiveBuffer.index(after: high)
                length = Int(receiveBuffer[high]) << 8 | Int(receiveBuffer[low])
                headerLength = 4
            } else if length == 127 {
                guard receiveBuffer.count >= 10 else { break }
                var value: UInt64 = 0
                for offset in 0..<8 {
                    let index = receiveBuffer.index(
                        receiveBuffer.startIndex,
                        offsetBy: 2 + offset
                    )
                    value = (value << 8) | UInt64(receiveBuffer[index])
                }
                guard value <= UInt64(Self.maximumPayload),
                      value <= UInt64(Int.max) else {
                    throw VLESSWebSocketTunnelError.messageTooLarge
                }
                length = Int(value)
                headerLength = 10
            }
            guard length <= Self.maximumPayload else {
                throw VLESSWebSocketTunnelError.messageTooLarge
            }
            if opcode == 0x8 || opcode == 0xA, length > 125 {
                throw VLESSWebSocketTunnelError.invalidFrame
            }
            guard receiveBuffer.count >= headerLength + length else { break }
            let bodyStart = receiveBuffer.index(
                receiveBuffer.startIndex,
                offsetBy: headerLength
            )
            let bodyEnd = receiveBuffer.index(bodyStart, offsetBy: length)
            let body = Data(receiveBuffer[bodyStart..<bodyEnd])
            if opcode == 0x2 {
                output.append(contentsOf: try responseDecoder.append(body))
            }
            receiveBuffer.removeFirst(headerLength + length)
        }
        return output
    }

    private static func frame(
        _ payload: Data,
        opcode: UInt8,
        mask: Bool
    ) throws -> Data {
        guard payload.count <= Self.maximumPayload else {
            throw VLESSWebSocketTunnelError.messageTooLarge
        }
        guard opcode == 0x2 || opcode == 0x8 else {
            throw VLESSWebSocketTunnelError.invalidFrame
        }
        var result = Data([0x80 | opcode])
        let flag: UInt8 = mask ? 0x80 : 0
        if payload.count < 126 {
            result.append(flag | UInt8(payload.count))
        } else if payload.count <= 65_535 {
            result.append(flag | 126)
            result.append(UInt8(payload.count >> 8))
            result.append(UInt8(payload.count & 0xff))
        } else {
            result.append(flag | 127)
            for shift in stride(from: 56, through: 0, by: -8) {
                result.append(UInt8(
                    truncatingIfNeeded: UInt64(payload.count) >> UInt64(shift)
                ))
            }
        }
        if mask {
            var generator = SystemRandomNumberGenerator()
            let key = (0..<4).map { _ in
                UInt8.random(in: 0...UInt8.max, using: &generator)
            }
            result.append(contentsOf: key)
            for (index, byte) in payload.enumerated() {
                result.append(byte ^ key[index % 4])
            }
        } else {
            result.append(payload)
        }
        return result
    }
}
