import Foundation

/// The address records extracted from one validated DNS response.  This is a
/// connector-neutral value: no packet contents or transport details are kept.
public struct DNSResolutionRecord: Sendable, Equatable {
    public let hostname: String
    public let addresses: [IPAddress]
    public let aliases: [String: String]
    public let ttl: UInt32

    public init(hostname: String, addresses: [IPAddress], aliases: [String: String] = [:], ttl: UInt32) {
        self.hostname = hostname
        self.addresses = addresses
        self.aliases = aliases
        self.ttl = ttl
    }
}

public enum DNSResolutionRecordParserError: Error, Equatable, Sendable {
    case malformedMessage
    case truncated
    case invalidName
    case compressionLoop
    case unsupportedRecord
}

/// Bounded DNS answer parser used for attribution. It validates the question,
/// all answer boundaries and compression pointers before exposing A/AAAA data.
public enum DNSResolutionRecordParser {
    public static func parse(_ message: Data, maximumRecords: Int = 4_096) throws -> DNSResolutionRecord {
        guard message.count >= 12, message.count <= DNSUpstreamLimits.maximumMessageBytes else { throw DNSResolutionRecordParserError.malformedMessage }
        let flags = try u16(message, 2)
        guard flags & 0x8000 != 0, flags & 0x0200 == 0, flags & 0x000F == 0 else { throw DNSResolutionRecordParserError.malformedMessage }
        let questions = Int(try u16(message, 4)), answers = Int(try u16(message, 6))
        let authorities = Int(try u16(message, 8)), additional = Int(try u16(message, 10))
        guard questions == 1, answers + authorities + additional <= maximumRecords else { throw DNSResolutionRecordParserError.malformedMessage }
        var offset = 12
        let question = try name(message, offset: &offset)
        let qtype = try u16(message, &offset), qclass = try u16(message, &offset)
        guard qclass == 1, qtype == 1 || qtype == 28 else { throw DNSResolutionRecordParserError.unsupportedRecord }
        var addressesByOwner: [String: [IPAddress]] = [:]
        var aliases: [String: String] = [:]
        var ttl = UInt32.max
        for section in 0..<3 {
            let count = [answers, authorities, additional][section]
            for _ in 0..<count {
                let owner = try name(message, offset: &offset)
                let type = try u16(message, &offset), klass = try u16(message, &offset)
                let recordTTL = try u32(message, &offset)
                let length = Int(try u16(message, &offset))
                guard length <= DNSUpstreamLimits.maximumMessageBytes, offset <= message.count - length else { throw DNSResolutionRecordParserError.truncated }
                let end = offset + length
                if section == 0, klass == 1, (type == 1 || type == 28) {
                    guard length == (type == 1 ? 4 : 16) else { throw DNSResolutionRecordParserError.malformedMessage }
                    let bytes = Array(message[offset..<end])
                    let text = type == 1 ? bytes.map(String.init).joined(separator: ".") : ipv6(bytes)
                    guard let address = try? IPAddress(text) else { throw DNSResolutionRecordParserError.malformedMessage }
                    addressesByOwner[owner, default: []].append(address); ttl = min(ttl, recordTTL)
                } else if section == 0, klass == 1, type == 5 {
                    var cnameOffset = offset
                    let target = try name(message, offset: &cnameOffset)
                    guard cnameOffset == end else { throw DNSResolutionRecordParserError.malformedMessage }
                    aliases[owner] = target; ttl = min(ttl, recordTTL)
                }
                offset = end
            }
        }
        var addresses: [IPAddress] = []
        var current = question
        var visited = Set<String>()
        for _ in 0..<16 {
            guard visited.insert(current).inserted else { throw DNSResolutionRecordParserError.compressionLoop }
            addresses.append(contentsOf: addressesByOwner[current] ?? [])
            guard let next = aliases[current] else { break }
            current = next
        }
        guard !addresses.isEmpty else { throw DNSResolutionRecordParserError.malformedMessage }
        return DNSResolutionRecord(hostname: question, addresses: addresses, aliases: aliases, ttl: ttl == .max ? 0 : ttl)
    }

    private static func u16(_ data: Data, _ at: Int) throws -> UInt16 { guard at >= 0, at <= data.count - 2 else { throw DNSResolutionRecordParserError.truncated }; return UInt16(data[data.index(data.startIndex, offsetBy: at)]) << 8 | UInt16(data[data.index(data.startIndex, offsetBy: at + 1)]) }
    private static func u16(_ data: Data, _ offset: inout Int) throws -> UInt16 { let value = try u16(data, offset); offset += 2; return value }
    private static func u32(_ data: Data, _ offset: inout Int) throws -> UInt32 { guard offset <= data.count - 4 else { throw DNSResolutionRecordParserError.truncated }; let value = UInt32(data[data.index(data.startIndex, offsetBy: offset)]) << 24 | UInt32(data[data.index(data.startIndex, offsetBy: offset + 1)]) << 16 | UInt32(data[data.index(data.startIndex, offsetBy: offset + 2)]) << 8 | UInt32(data[data.index(data.startIndex, offsetBy: offset + 3)]); offset += 4; return value }
    private static func name(_ data: Data, offset: inout Int) throws -> String {
        var position = offset, jumped = false, labels: [String] = [], visited = Set<Int>(), steps = 0, bytes = 0
        while true {
            guard position < data.count, steps < 128 else { throw DNSResolutionRecordParserError.invalidName }; steps += 1
            let length = Int(data[data.index(data.startIndex, offsetBy: position)])
            if length == 0 { if !jumped { offset = position + 1 }; return labels.joined(separator: ".").lowercased() }
            if length & 0xC0 == 0xC0 {
                guard position + 1 < data.count else { throw DNSResolutionRecordParserError.truncated }
                let pointer = ((length & 0x3F) << 8) | Int(data[data.index(data.startIndex, offsetBy: position + 1)])
                guard pointer < data.count, visited.insert(pointer).inserted else { throw DNSResolutionRecordParserError.compressionLoop }
                if !jumped { offset = position + 2; jumped = true }; position = pointer; continue
            }
            guard length <= 63, position + 1 + length <= data.count, bytes + length + 1 <= 253 else { throw DNSResolutionRecordParserError.invalidName }
            let start = data.index(data.startIndex, offsetBy: position + 1), end = data.index(start, offsetBy: length)
            guard let label = String(bytes: data[start..<end], encoding: .utf8), !label.isEmpty else { throw DNSResolutionRecordParserError.invalidName }
            labels.append(label); bytes += length + 1; position = position + 1 + length
        }
    }
    private static func ipv6(_ bytes: [UInt8]) -> String { (0..<8).map { String(format: "%x", UInt16(bytes[$0 * 2]) << 8 | UInt16(bytes[$0 * 2 + 1])) }.joined(separator: ":") }
}

/// Short-lived, bounded association between a captured destination and the
/// hostname that produced it. Ambiguous addresses intentionally return nil.
public actor DNSResolutionAssociationStore {
    public struct Key: Hashable, Sendable { public let sourceIdentity: String; public let address: IPAddress; public let configurationRevision: Int; public let generation: Int; public init(sourceIdentity: String, address: IPAddress, configurationRevision: Int, generation: Int) { self.sourceIdentity = sourceIdentity; self.address = address; self.configurationRevision = configurationRevision; self.generation = generation } }
    private struct Entry: Sendable { var hostnames: Set<String>; let expires: Date; var touched: UInt64 }
    private var entries: [Key: Entry] = [:]
    private var clock: UInt64 = 0
    public let maximumEntries: Int
    public let maximumEntriesPerSource: Int
    public let minimumTTL: TimeInterval
    public let maximumTTL: TimeInterval

    public init(maximumEntries: Int = 4_096, maximumEntriesPerSource: Int = 512, minimumTTL: TimeInterval = 1, maximumTTL: TimeInterval = 86_400) {
        self.maximumEntries = max(1, maximumEntries); self.maximumEntriesPerSource = max(1, maximumEntriesPerSource); self.minimumTTL = max(0, minimumTTL); self.maximumTTL = max(self.minimumTTL, maximumTTL)
    }
    public func associate(hostname: String, addresses: [IPAddress], sourceIdentity: String, configurationRevision: Int, generation: Int, ttl: UInt32, now: Date = Date()) {
        let host = hostname.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")); guard !host.isEmpty else { return }
        purgeExpired(now: now); let expiry = now.addingTimeInterval(min(max(Double(ttl), minimumTTL), maximumTTL))
        for address in Set(addresses) { let key = Key(sourceIdentity: sourceIdentity, address: address, configurationRevision: configurationRevision, generation: generation); clock += 1; if let existing = entries[key] { entries[key] = Entry(hostnames: existing.hostnames.union([host]), expires: max(existing.expires, expiry), touched: clock) } else { entries[key] = Entry(hostnames: [host], expires: expiry, touched: clock) }; enforceLimits(sourceIdentity: sourceIdentity) }
        enforceGlobalLimit()
    }
    public func hostname(for address: IPAddress, sourceIdentity: String, configurationRevision: Int, generation: Int, now: Date = Date()) -> String? {
        purgeExpired(now: now); let key = Key(sourceIdentity: sourceIdentity, address: address, configurationRevision: configurationRevision, generation: generation); guard let entry = entries[key], entry.hostnames.count == 1 else { return nil }; clock += 1; entries[key]?.touched = clock; return entry.hostnames.first
    }
    public func count(now: Date = Date()) -> Int { purgeExpired(now: now); return entries.count }
    private func purgeExpired(now: Date) { entries = entries.filter { $0.value.expires > now } }
    private func enforceLimits(sourceIdentity: String) { while entries.filter({ $0.key.sourceIdentity == sourceIdentity }).count > maximumEntriesPerSource { if let victim = entries.filter({ $0.key.sourceIdentity == sourceIdentity }).min(by: { $0.value.touched < $1.value.touched })?.key { entries.removeValue(forKey: victim) } } }
    private func enforceGlobalLimit() { while entries.count > maximumEntries { if let victim = entries.min(by: { $0.value.touched < $1.value.touched })?.key { entries.removeValue(forKey: victim) } } }
}
