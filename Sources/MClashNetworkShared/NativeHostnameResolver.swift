import Foundation

/// A small DNS resolver used by native connectors.  It deliberately accepts
/// only literal-IP bootstrap endpoints and never consults the host resolver;
/// this keeps connector bootstrap deterministic and avoids recursive proxy
/// lookups.
public struct NativeHostnameResolver: Sendable {
    public enum Error: Swift.Error, Equatable, Sendable {
        case invalidHostname
        case noAddress
        case allUpstreamsFailed
    }

    public enum RecordType: UInt16, Sendable {
        case a = 1
        case aaaa = 28
    }

    private let bootstrap: DNSUpstreamBootstrap
    private let makeUpstream: @Sendable (DNSUpstreamEndpoint) -> any DNSUpstream

    public init(
        bootstrap: DNSUpstreamBootstrap,
        makeUpstream: @escaping @Sendable (DNSUpstreamEndpoint) -> any DNSUpstream = { SocketDNSUpstream(endpoint: $0) }
    ) {
        self.bootstrap = bootstrap
        self.makeUpstream = makeUpstream
    }

    /// Resolve A and AAAA records in a stable family/address order. Each
    /// configured endpoint is tried in declaration order; a timeout or bad
    /// packet never prevents the next endpoint from being used.
    public func resolve(_ hostname: String) async throws -> [IPAddress] {
        let name = try Self.normalizedHostname(hostname)
        var hadUsableResponse = false
        for endpoint in bootstrap.endpoints {
            var addresses: [IPAddress] = []
            for type in [RecordType.a, .aaaa] {
                do {
                    let query = try Self.query(for: name, type: type, transactionID: Self.transactionID())
                    let response = try await makeUpstream(endpoint).exchange(query: query)
                    let id = try DNSWireMessage.transactionID(of: query)
                    try DNSWireMessage.validateResponse(response, matching: id, transport: endpoint.transport)
                    hadUsableResponse = true
                    addresses.append(contentsOf: try Self.parseAddresses(response, name: name, type: type))
                } catch {
                    // A malformed/unavailable family is isolated. The next
                    // family and then the next literal-IP upstream still run.
                }
            }
            let unique = Self.stableUnique(addresses)
            if !unique.isEmpty { return unique }
        }
        if hadUsableResponse { throw Error.noAddress }
        throw Error.allUpstreamsFailed
    }

    /// Encodes one bounded IN question. Kept public for packet-level tests
    /// and for connectors that need to preflight a hostname without sending.
    public static func query(for hostname: String, type: RecordType, transactionID: UInt16) throws -> Data {
        let name = try normalizedHostname(hostname)
        var output = Data([UInt8(transactionID >> 8), UInt8(transactionID & 0xff), 0x01, 0x00, 0x00, 0x01, 0, 0, 0, 0, 0, 0])
        for label in name.split(separator: ".", omittingEmptySubsequences: true) {
            output.append(UInt8(label.utf8.count))
            output.append(contentsOf: label.utf8)
        }
        output.append(0)
        output.append(UInt8(type.rawValue >> 8)); output.append(UInt8(type.rawValue & 0xff))
        output.append(0); output.append(1)
        guard output.count <= DNSUpstreamLimits.maximumUDPMessageBytes else {
            throw Error.invalidHostname
        }
        return output
    }

    /// Parses answer records without following pointers outside the packet.
    /// Compression loops, out-of-range pointers, and truncated RDATA are
    /// rejected before any address is exposed to the routing layer.
    public static func parseAddresses(_ response: Data, name: String, type: RecordType) throws -> [IPAddress] {
        guard response.count >= 12 else { throw Error.allUpstreamsFailed }
        let qd = try count(response, at: 4), an = try count(response, at: 6)
        let ns = try count(response, at: 8), ar = try count(response, at: 10)
        var offset = 12
        for _ in 0..<qd { _ = try readName(response, offset: &offset); try skip(response, offset: &offset, count: 4) }
        var values: [IPAddress] = []
        for (sectionIndex, sectionCount) in [an, ns, ar].enumerated() {
            for _ in 0..<sectionCount {
                _ = try readName(response, offset: &offset)
                let rrType = try readUInt16(response, offset: &offset)
                _ = try readUInt16(response, offset: &offset) // class
                _ = try readUInt32(response, offset: &offset)
                let length = Int(try readUInt16(response, offset: &offset))
                guard offset + length <= response.count else { throw Error.allUpstreamsFailed }
                if sectionIndex == 0, rrType == type.rawValue {
                    guard length == (type == .a ? 4 : 16) else { throw Error.allUpstreamsFailed }
                    let bytes = Array(response[offset..<(offset + length)])
                    values.append(try IPAddress(type == .a ? bytes.map(String.init).joined(separator: ".") : ipv6Text(bytes)))
                }
                offset += length
            }
        }
        return stableUnique(values)
    }

    private static func normalizedHostname(_ value: String) throws -> String {
        var name = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if name.last == "." { name.removeLast() }
        guard !name.isEmpty, name.utf8.count <= DNSUpstreamLimits.maximumNameBytes else { throw Error.invalidHostname }
        let labels = name.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.allSatisfy({ label in
            let bytes = Array(label.utf8)
            return (1...63).contains(bytes.count) && bytes.allSatisfy { $0 == 45 || $0 == 46 || ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 122) } && bytes.first != 45 && bytes.last != 45
        }) else { throw Error.invalidHostname }
        return name
    }

    private static func readName(_ data: Data, offset: inout Int) throws -> String {
        var position = offset, jumped = false, labels: [String] = [], visited = Set<Int>(), steps = 0
        while true {
            guard position < data.count, steps < 128 else { throw Error.allUpstreamsFailed }; steps += 1
            let length = Int(data[position])
            if length == 0 { if !jumped { offset = position + 1 }; return labels.joined(separator: ".") }
            if length & 0xc0 == 0xc0 {
                guard position + 1 < data.count else { throw Error.allUpstreamsFailed }
                let pointer = ((length & 0x3f) << 8) | Int(data[position + 1])
                guard pointer < data.count, visited.insert(pointer).inserted else { throw Error.allUpstreamsFailed }
                if !jumped { offset = position + 2; jumped = true }; position = pointer; continue
            }
            guard length <= 63, position + 1 + length <= data.count else { throw Error.allUpstreamsFailed }
            labels.append(String(decoding: data[(position + 1)..<(position + 1 + length)], as: UTF8.self)); position += length + 1
        }
    }

    private static func skip(_ data: Data, offset: inout Int, count: Int) throws { guard count >= 0, offset + count <= data.count else { throw Error.allUpstreamsFailed }; offset += count }
    private static func readUInt16(_ data: Data, offset: inout Int) throws -> UInt16 { guard offset + 2 <= data.count else { throw Error.allUpstreamsFailed }; defer { offset += 2 }; return UInt16(data[offset]) << 8 | UInt16(data[offset + 1]) }
    private static func readUInt32(_ data: Data, offset: inout Int) throws -> UInt32 { guard offset + 4 <= data.count else { throw Error.allUpstreamsFailed }; defer { offset += 4 }; return UInt32(data[offset]) << 24 | UInt32(data[offset + 1]) << 16 | UInt32(data[offset + 2]) << 8 | UInt32(data[offset + 3]) }
    private static func count(_ data: Data, at index: Int) throws -> Int { guard index + 1 < data.count else { throw Error.allUpstreamsFailed }; return Int(UInt16(data[index]) << 8 | UInt16(data[index + 1])) }
    private static func transactionID() -> UInt16 { UInt16.random(in: UInt16.min...UInt16.max) }
    private static func stableUnique(_ values: [IPAddress]) -> [IPAddress] { var seen = Set<IPAddress>(); return values.filter { seen.insert($0).inserted } }
    private static func ipv6Text(_ bytes: [UInt8]) -> String { (0..<8).map { String(format: "%x", UInt16(bytes[$0 * 2]) << 8 | UInt16(bytes[$0 * 2 + 1])) }.joined(separator: ":") }
}
