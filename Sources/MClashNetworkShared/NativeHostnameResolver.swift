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
        for endpoint in bootstrap.orderedEndpoints(for: name) {
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

    /// Resolves only connector endpoint hostnames and preserves the original
    /// host for SNI/Host/protocol semantics. Resolution failure leaves that
    /// target unchanged so the caller can expose a bounded fallback instead
    /// of dropping an otherwise valid configuration.
    public func resolving(
        _ catalog: OutboundNodeTargetCatalog
    ) async -> OutboundNodeTargetCatalog {
        var cache: [String: String] = [:]
        var attempted = Set<String>()
        var entries: [OutboundNodeTargetEntry] = []
        entries.reserveCapacity(catalog.entries.count)
        for entry in catalog.entries {
            let target = entry.target
            guard (try? IPAddress(target.host)) == nil else {
                entries.append(entry)
                continue
            }
            let normalized = target.host.lowercased()
            let resolvedAddress: String?
            if attempted.contains(normalized) {
                resolvedAddress = cache[normalized]
            } else {
                attempted.insert(normalized)
                let addresses = try? await resolve(target.host)
                resolvedAddress = addresses?.first(where: { $0.family == .ipv4 })?.presentation
                    ?? addresses?.first?.presentation
                if let resolvedAddress { cache[normalized] = resolvedAddress }
            }
            guard let resolvedAddress else {
                entries.append(entry)
                continue
            }
            var parameters = target.parameters
            parameters[OutboundNodeTarget.resolvedAddressParameterKey] = resolvedAddress
            guard let resolvedTarget = try? OutboundNodeTarget(
                protocolName: target.protocolName,
                host: target.host,
                port: target.port,
                parameters: parameters
            ) else {
                entries.append(entry)
                continue
            }
            entries.append(.init(route: entry.route, target: resolvedTarget))
        }
        return (try? OutboundNodeTargetCatalog(entries: entries)) ?? catalog
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
        let expectedName = try normalizedHostname(name)
        let flags = try count(response, at: 2)
        guard flags & 0x000f == 0, flags & 0x0200 == 0 else {
            throw Error.allUpstreamsFailed
        }
        let qd = try count(response, at: 4), an = try count(response, at: 6)
        let ns = try count(response, at: 8), ar = try count(response, at: 10)
        guard qd == 1 else { throw Error.allUpstreamsFailed }
        var offset = 12
        let questionName = try readName(response, offset: &offset).lowercased()
        let questionType = try readUInt16(response, offset: &offset)
        let questionClass = try readUInt16(response, offset: &offset)
        guard questionName == expectedName,
              questionType == type.rawValue,
              questionClass == 1 else {
            throw Error.allUpstreamsFailed
        }
        var addressesByName: [String: [IPAddress]] = [:]
        var aliases: [String: String] = [:]
        for (sectionIndex, sectionCount) in [an, ns, ar].enumerated() {
            for _ in 0..<sectionCount {
                let owner = try readName(response, offset: &offset).lowercased()
                let rrType = try readUInt16(response, offset: &offset)
                let rrClass = try readUInt16(response, offset: &offset)
                _ = try readUInt32(response, offset: &offset)
                let length = Int(try readUInt16(response, offset: &offset))
                guard offset + length <= response.count else { throw Error.allUpstreamsFailed }
                let rdataEnd = offset + length
                if sectionIndex == 0, rrClass == 1, rrType == type.rawValue {
                    guard length == (type == .a ? 4 : 16) else { throw Error.allUpstreamsFailed }
                    let addressStart = response.index(response.startIndex, offsetBy: offset)
                    let addressEnd = response.index(addressStart, offsetBy: length)
                    let bytes = Array(response[addressStart..<addressEnd])
                    addressesByName[owner, default: []].append(
                        try IPAddress(
                            type == .a
                                ? bytes.map(String.init).joined(separator: ".")
                                : ipv6Text(bytes)
                        )
                    )
                } else if sectionIndex == 0, rrClass == 1, rrType == 5 {
                    var aliasOffset = offset
                    let target = try readName(response, offset: &aliasOffset).lowercased()
                    guard aliasOffset <= rdataEnd else { throw Error.allUpstreamsFailed }
                    aliases[owner] = target
                }
                offset = rdataEnd
            }
        }
        var values: [IPAddress] = []
        var current = expectedName
        var visited = Set<String>()
        for _ in 0..<16 {
            guard visited.insert(current).inserted else {
                throw Error.allUpstreamsFailed
            }
            values.append(contentsOf: addressesByName[current] ?? [])
            guard let next = aliases[current] else { break }
            current = next
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
            let length = Int(byte(data, at: position))
            if length == 0 { if !jumped { offset = position + 1 }; return labels.joined(separator: ".") }
            if length & 0xc0 == 0xc0 {
                guard position + 1 < data.count else { throw Error.allUpstreamsFailed }
                let pointer = ((length & 0x3f) << 8) | Int(byte(data, at: position + 1))
                guard pointer < data.count, visited.insert(pointer).inserted else { throw Error.allUpstreamsFailed }
                if !jumped { offset = position + 2; jumped = true }; position = pointer; continue
            }
            guard length <= 63, position + 1 + length <= data.count else { throw Error.allUpstreamsFailed }
            let labelStart = data.index(data.startIndex, offsetBy: position + 1)
            let labelEnd = data.index(labelStart, offsetBy: length)
            labels.append(String(decoding: data[labelStart..<labelEnd], as: UTF8.self)); position += length + 1
        }
    }

    private static func readUInt16(_ data: Data, offset: inout Int) throws -> UInt16 { guard offset + 2 <= data.count else { throw Error.allUpstreamsFailed }; defer { offset += 2 }; return UInt16(byte(data, at: offset)) << 8 | UInt16(byte(data, at: offset + 1)) }
    private static func readUInt32(_ data: Data, offset: inout Int) throws -> UInt32 { guard offset + 4 <= data.count else { throw Error.allUpstreamsFailed }; defer { offset += 4 }; return UInt32(byte(data, at: offset)) << 24 | UInt32(byte(data, at: offset + 1)) << 16 | UInt32(byte(data, at: offset + 2)) << 8 | UInt32(byte(data, at: offset + 3)) }
    private static func count(_ data: Data, at index: Int) throws -> Int { guard index + 1 < data.count else { throw Error.allUpstreamsFailed }; return Int(UInt16(byte(data, at: index)) << 8 | UInt16(byte(data, at: index + 1))) }
    private static func byte(_ data: Data, at offset: Int) -> UInt8 { data[data.index(data.startIndex, offsetBy: offset)] }
    private static func transactionID() -> UInt16 { UInt16.random(in: UInt16.min...UInt16.max) }
    private static func stableUnique(_ values: [IPAddress]) -> [IPAddress] { var seen = Set<IPAddress>(); return values.filter { seen.insert($0).inserted } }
    private static func ipv6Text(_ bytes: [UInt8]) -> String { (0..<8).map { String(format: "%x", UInt16(bytes[$0 * 2]) << 8 | UInt16(bytes[$0 * 2 + 1])) }.joined(separator: ":") }
}
