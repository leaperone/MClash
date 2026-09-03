import Darwin
import Foundation

/// Limits applied before a DNS packet is sent to an upstream.  Keeping these
/// limits here prevents a malformed capture from turning into unbounded socket
/// or buffer work.
public enum DNSUpstreamLimits: Sendable {
    public static let maximumMessageBytes = 65_535
    public static let maximumUDPMessageBytes = 4_096
    public static let maximumTCPFrameBytes = 65_535
    public static let maximumNameBytes = 253
}

public enum DNSUpstreamError: Error, Equatable, Sendable {
    case invalidEndpoint
    case invalidMessage(String)
    case messageTooLarge(limit: Int, actual: Int)
    case timeout
    case socketFailure(String)
    case mismatchedTransactionID
}

public enum DNSUpstreamTransport: String, Codable, Sendable, Equatable {
    case udp
    case tcp
}

/// Selects who owns public DNS transport.
///
/// `legacyConnector` is deliberately named after its role rather than the
/// implementation that used to provide it.  The old `"mihomo"` wire value is
/// still accepted when decoding persisted bootstrap payloads, but newly
/// encoded payloads use the role-oriented `"legacyConnector"` value.
public enum DNSUpstreamMode: String, Codable, Sendable, Equatable {
    case legacyConnector
    case native

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        switch value {
        case "legacyConnector", "legacy", "mihomo":
            self = .legacyConnector
        case "native":
            self = .native
        default:
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported DNS upstream mode: \(value)"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public struct DNSUpstreamEndpoint: Codable, Sendable, Hashable, Equatable {
    public let address: IPAddress
    public let port: UInt16
    public let transport: DNSUpstreamTransport
    public let timeoutMilliseconds: Int

    private enum CodingKeys: String, CodingKey {
        case address, port, transport, timeoutMilliseconds
    }

    public init(address: IPAddress, port: UInt16 = 53, transport: DNSUpstreamTransport,
                timeoutMilliseconds: Int = 2_000) throws {
        guard port > 0, (100 ... 60_000).contains(timeoutMilliseconds) else {
            throw DNSUpstreamError.invalidEndpoint
        }
        self.address = address
        self.port = port
        self.transport = transport
        self.timeoutMilliseconds = timeoutMilliseconds
    }

    /// Keep the wire representation stable and human-readable.  IPAddress is
    /// intentionally not Codable because it is also used by packet parsers;
    /// DNS bootstrap payloads carry its canonical presentation instead.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let address = try IPAddress(container.decode(String.self, forKey: .address))
        try self.init(
            address: address,
            port: container.decode(UInt16.self, forKey: .port),
            transport: container.decode(DNSUpstreamTransport.self, forKey: .transport),
            timeoutMilliseconds: container.decode(Int.self, forKey: .timeoutMilliseconds)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(address.presentation, forKey: .address)
        try container.encode(port, forKey: .port)
        try container.encode(transport, forKey: .transport)
        try container.encode(timeoutMilliseconds, forKey: .timeoutMilliseconds)
    }
}

/// Connector-neutral native DNS upstreams supplied by MClash.  This payload
/// describes DNS transport only; it deliberately contains no Mihomo listener,
/// SOCKS port, or route endpoint.  Native DNS can therefore be bootstrapped
/// even after the Mihomo control/data plane has been removed.
public struct DNSUpstreamBootstrap: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1
    public static let maximumEntries = 16
    public static let maximumEncodedBytes = 16 * 1_024

    public let schemaVersion: Int
    public let endpoints: [DNSUpstreamEndpoint]

    public init(endpoints: [DNSUpstreamEndpoint]) throws {
        guard !endpoints.isEmpty, endpoints.count <= Self.maximumEntries else {
            throw DNSUpstreamBootstrapError.invalidEndpointCount
        }
        var seen = Set<DNSUpstreamEndpoint>()
        guard endpoints.allSatisfy({ seen.insert($0).inserted }) else {
            throw DNSUpstreamBootstrapError.duplicateEndpoint
        }
        schemaVersion = Self.currentSchemaVersion
        self.endpoints = endpoints
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decode(Int.self, forKey: .schemaVersion)
        guard version == Self.currentSchemaVersion else {
            throw DNSUpstreamBootstrapError.unsupportedSchemaVersion(version)
        }
        try self.init(endpoints: container.decode([DNSUpstreamEndpoint].self, forKey: .endpoints))
    }

    private enum CodingKeys: String, CodingKey { case schemaVersion, endpoints }

    public func encoded() throws -> Data {
        let data = try JSONEncoder().encode(self)
        guard data.count <= Self.maximumEncodedBytes else {
            throw DNSUpstreamBootstrapError.encodedPayloadTooLarge
        }
        return data
    }

    public static func decode(_ data: Data) throws -> Self {
        guard data.count <= maximumEncodedBytes else {
            throw DNSUpstreamBootstrapError.encodedPayloadTooLarge
        }
        return try JSONDecoder().decode(Self.self, from: data)
    }

    /// The first endpoint is the deterministic bootstrap choice.  Failover
    /// policy belongs to the resolver and can be added without changing the
    /// connector-neutral wire contract.
    public var primary: DNSUpstreamEndpoint { endpoints[0] }

    /// The reason a native resolver selected an endpoint. Keeping this
    /// explicit makes fallback observable without exposing a query or an
    /// upstream credential in diagnostics.
    public enum SelectionReason: String, Codable, Equatable, Sendable {
        case exactAddress
        case firstMatchingTransport
        case noMatchingTransport
    }

    public struct Selection: Codable, Equatable, Sendable {
        public let endpoint: DNSUpstreamEndpoint?
        public let reason: SelectionReason

        public init(endpoint: DNSUpstreamEndpoint?, reason: SelectionReason) {
            self.endpoint = endpoint
            self.reason = reason
        }
    }

    /// Selects an upstream deterministically. An intercepted resolver address
    /// is only a hint: if it is not configured, the first endpoint in the
    /// user's ordered bootstrap with the same wire transport wins. No
    /// unordered set/dictionary participates in this decision.
    public func select(
        interceptedAddress: IPAddress?,
        transport: DNSUpstreamTransport
    ) -> Selection {
        let matching = endpoints.filter { $0.transport == transport }
        guard !matching.isEmpty else {
            return Selection(endpoint: nil, reason: .noMatchingTransport)
        }
        if let interceptedAddress,
           let exact = matching.first(where: { $0.address == interceptedAddress }) {
            return Selection(endpoint: exact, reason: .exactAddress)
        }
        return Selection(endpoint: matching[0], reason: .firstMatchingTransport)
    }
}

public enum DNSUpstreamBootstrapError: Error, Equatable, Sendable {
    case invalidEndpointCount
    case duplicateEndpoint
    case unsupportedSchemaVersion(Int)
    case encodedPayloadTooLarge
}

/// The small, connector-neutral contract used by MClash's DNS router.
public protocol DNSUpstream: Sendable {
    func exchange(query: Data) async throws -> Data
}

/// DNS wire framing and safety checks. This does not interpret records; the
/// router may pass the validated response on to its own policy/cache layer.
public enum DNSWireMessage {
    public static func transactionID(of message: Data) throws -> UInt16 {
        guard message.count >= 12 else { throw DNSUpstreamError.invalidMessage("DNS header is truncated") }
        return UInt16(message[message.startIndex]) << 8 | UInt16(message[message.startIndex + 1])
    }

    public static func validateQuery(_ query: Data, transport: DNSUpstreamTransport) throws -> UInt16 {
        try validateSize(query, limit: transport == .udp ? DNSUpstreamLimits.maximumUDPMessageBytes : DNSUpstreamLimits.maximumMessageBytes)
        guard query.count >= 12 else { throw DNSUpstreamError.invalidMessage("DNS header is truncated") }
        let flags = UInt16(query[2]) << 8 | UInt16(query[3])
        guard flags & 0x8000 == 0 else { throw DNSUpstreamError.invalidMessage("query has response flag") }
        let questions = UInt16(query[4]) << 8 | UInt16(query[5])
        guard questions > 0 else { throw DNSUpstreamError.invalidMessage("query has no questions") }
        return try transactionID(of: query)
    }

    public static func validateResponse(_ response: Data, matching transactionID: UInt16,
                                        transport: DNSUpstreamTransport) throws {
        try validateSize(response, limit: transport == .udp ? DNSUpstreamLimits.maximumUDPMessageBytes : DNSUpstreamLimits.maximumMessageBytes)
        guard response.count >= 12 else { throw DNSUpstreamError.invalidMessage("DNS response header is truncated") }
        guard try Self.transactionID(of: response) == transactionID else { throw DNSUpstreamError.mismatchedTransactionID }
        let flags = UInt16(response[2]) << 8 | UInt16(response[3])
        guard flags & 0x8000 != 0 else { throw DNSUpstreamError.invalidMessage("response flag is missing") }
        let questions = UInt16(response[4]) << 8 | UInt16(response[5])
        guard questions > 0 else { throw DNSUpstreamError.invalidMessage("response has no questions") }
    }

    public static func tcpFrame(for message: Data) throws -> Data {
        try validateSize(message, limit: DNSUpstreamLimits.maximumMessageBytes)
        guard message.count >= 12 else { throw DNSUpstreamError.invalidMessage("DNS message is truncated") }
        return Data([UInt8(message.count >> 8), UInt8(message.count & 0xff)]) + message
    }

    public static func message(fromTCPFrame frame: Data) throws -> Data {
        guard frame.count >= 2 else { throw DNSUpstreamError.invalidMessage("TCP DNS length is truncated") }
        let length = Int(frame[0]) << 8 | Int(frame[1])
        guard length > 0, length <= DNSUpstreamLimits.maximumTCPFrameBytes else {
            throw DNSUpstreamError.messageTooLarge(limit: DNSUpstreamLimits.maximumTCPFrameBytes, actual: length)
        }
        guard frame.count == length + 2 else { throw DNSUpstreamError.invalidMessage("TCP DNS frame length mismatch") }
        return Data(frame.dropFirst(2))
    }

    private static func validateSize(_ message: Data, limit: Int) throws {
        guard message.count <= limit else { throw DNSUpstreamError.messageTooLarge(limit: limit, actual: message.count) }
    }
}

/// POSIX UDP/TCP implementation. It is deliberately only an upstream
/// transport: routing, caching, and policy remain owned by MClash.
public struct SocketDNSUpstream: DNSUpstream {
    public let endpoint: DNSUpstreamEndpoint

    public init(endpoint: DNSUpstreamEndpoint) { self.endpoint = endpoint }

    public func exchange(query: Data) async throws -> Data {
        let id = try DNSWireMessage.validateQuery(query, transport: endpoint.transport)
        let endpoint = self.endpoint
        return try await Task.detached(priority: .userInitiated) {
            let response = try POSIXDNSExchange(endpoint: endpoint).send(query: query)
            try DNSWireMessage.validateResponse(response, matching: id, transport: endpoint.transport)
            return response
        }.value
    }
}

private struct POSIXDNSExchange: Sendable {
    let endpoint: DNSUpstreamEndpoint

    func send(query: Data) throws -> Data {
        let family: Int32 = endpoint.address.family == .ipv4 ? AF_INET : AF_INET6
        let descriptor = socket(family, endpoint.transport == .udp ? SOCK_DGRAM : SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw DNSUpstreamError.socketFailure(String(cString: strerror(errno))) }
        defer { close(descriptor) }
        try setTimeout(descriptor)
        try withSockAddr { pointer, length in
            guard connect(descriptor, pointer, length) == 0 else { throw DNSUpstreamError.socketFailure(String(cString: strerror(errno))) }
        }
        let payload = endpoint.transport == .tcp ? try DNSWireMessage.tcpFrame(for: query) : query
        try writeAll(descriptor, data: payload)
        if endpoint.transport == .tcp {
            let prefix = try readExact(descriptor, count: 2)
            let length = Int(prefix[0]) << 8 | Int(prefix[1])
            guard length > 0, length <= DNSUpstreamLimits.maximumTCPFrameBytes else {
                throw DNSUpstreamError.messageTooLarge(limit: DNSUpstreamLimits.maximumTCPFrameBytes, actual: length)
            }
            return try readExact(descriptor, count: length)
        }
        var buffer = [UInt8](repeating: 0, count: DNSUpstreamLimits.maximumUDPMessageBytes)
        let count = recv(descriptor, &buffer, buffer.count, 0)
        guard count >= 0 else {
            if errno == EAGAIN || errno == EWOULDBLOCK || errno == ETIMEDOUT { throw DNSUpstreamError.timeout }
            throw DNSUpstreamError.socketFailure(String(cString: strerror(errno)))
        }
        return Data(buffer.prefix(count))
    }

    private func setTimeout(_ descriptor: Int32) throws {
        var timeout = timeval(tv_sec: endpoint.timeoutMilliseconds / 1_000,
                              tv_usec: Int32((endpoint.timeoutMilliseconds % 1_000) * 1_000))
        guard setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size)) == 0,
              setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size)) == 0 else {
            throw DNSUpstreamError.socketFailure(String(cString: strerror(errno)))
        }
    }

    private func withSockAddr<T>(_ body: (UnsafePointer<sockaddr>, socklen_t) throws -> T) throws -> T {
        if endpoint.address.family == .ipv4 {
            var value = sockaddr_in()
            value.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            value.sin_family = sa_family_t(AF_INET)
            value.sin_port = endpoint.port.bigEndian
            value.sin_addr = endpoint.address.bytes.withUnsafeBytes { $0.load(as: in_addr.self) }
            return try withUnsafePointer(to: &value) { try $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { try body($0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        }
        var value = sockaddr_in6()
        value.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        value.sin6_family = sa_family_t(AF_INET6)
        value.sin6_port = endpoint.port.bigEndian
        value.sin6_addr = endpoint.address.bytes.withUnsafeBytes { $0.load(as: in6_addr.self) }
        return try withUnsafePointer(to: &value) { try $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { try body($0, socklen_t(MemoryLayout<sockaddr_in6>.size)) } }
    }

    private func writeAll(_ descriptor: Int32, data: Data) throws {
        var offset = 0
        while offset < data.count {
            let written = data.withUnsafeBytes { write(descriptor, $0.baseAddress!.advanced(by: offset), data.count - offset) }
            guard written > 0 else {
                if errno == EAGAIN || errno == EWOULDBLOCK || errno == ETIMEDOUT { throw DNSUpstreamError.timeout }
                throw DNSUpstreamError.socketFailure(String(cString: strerror(errno)))
            }
            offset += written
        }
    }

    private func readExact(_ descriptor: Int32, count: Int) throws -> Data {
        var output = Data(); output.reserveCapacity(count)
        var buffer = [UInt8](repeating: 0, count: min(count, 16_384))
        while output.count < count {
            let wanted = min(buffer.count, count - output.count)
            let received = recv(descriptor, &buffer, wanted, 0)
            guard received > 0 else {
                if errno == EAGAIN || errno == EWOULDBLOCK || errno == ETIMEDOUT { throw DNSUpstreamError.timeout }
                throw DNSUpstreamError.socketFailure(String(cString: strerror(errno)))
            }
            output.append(contentsOf: buffer.prefix(received))
        }
        return output
    }
}
