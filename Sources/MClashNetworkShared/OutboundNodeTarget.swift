import Foundation

/// Connector-neutral node material. It contains only the connection fields a
/// transport implementation needs; routing policy and proxy-group selection
/// remain outside this value. Credential fields are intentionally opaque to the
/// policy engine and are never used as node identity.
public struct OutboundNodeTarget: Codable, Equatable, Hashable, Sendable {
    public static let resolvedAddressParameterKey = "resolved-address"
    public let protocolName: String
    public let host: String
    public let port: UInt16
    public let parameters: [String: String]

    /// Socket endpoint chosen by MClash's native DNS resolver. The original
    /// hostname remains available for TLS SNI, HTTP Host and protocol framing.
    public var connectionHost: String {
        guard let value = parameters[Self.resolvedAddressParameterKey],
              (try? IPAddress(value)) != nil else {
            return host
        }
        return value
    }

    /// Parsed VLESS WebSocket transport options, when this target declares a
    /// WebSocket network. Keeping parsing at the target boundary prevents the
    /// native connector and compatibility compiler from drifting apart.
    public var vlessWebSocketOptions: VLESSWebSocketOptions? {
        guard protocolName == "vless",
              parameters["network"]?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "ws"
        else { return nil }
        return VLESSWebSocketOptions.parse(parameters: parameters)
    }

    public init(protocolName: String, host: String, port: UInt16, parameters: [String: String] = [:]) throws {
        let normalizedProtocol = protocolName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let normalizedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedProtocol.isEmpty, !normalizedHost.isEmpty, port > 0 else {
            throw OutboundNodeTargetError.invalidEndpoint
        }
        guard normalizedProtocol.utf8.count <= 32, normalizedHost.utf8.count <= 255 else {
            throw OutboundNodeTargetError.fieldTooLong
        }
        self.protocolName = normalizedProtocol
        self.host = normalizedHost
        self.port = port
        self.parameters = parameters
    }
}

public enum OutboundNodeTargetError: Error, Equatable, Sendable {
    case invalidEndpoint
    case fieldTooLong
}
