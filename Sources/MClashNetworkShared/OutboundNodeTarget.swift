import Foundation

/// Connector-neutral node material. It contains only the connection fields a
/// transport implementation needs; routing policy and proxy-group selection
/// remain outside this value. Credential fields are intentionally opaque to the
/// policy engine and are never used as node identity.
public struct OutboundNodeTarget: Codable, Equatable, Hashable, Sendable {
    public let protocolName: String
    public let host: String
    public let port: UInt16
    public let parameters: [String: String]

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
