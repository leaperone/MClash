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
    public static func parse(_ message: Data, maximumRecords: Int = 256) throws -> DNSResolutionRecord {
        guard message.count >= 12, message.count <= DNSUpstreamLimits.maximumMessageBytes else { throw DNSResolutionRecordParserError.malformedMessage }
        let flags = try u16(message, 2)
        guard flags & 0x8000 != 0, flags & 0x0200 == 0, flags & 0x000F == 0 else { throw DNSResolutionRecordParserError.malformedMessage }
        let questions = Int(try u16(message, 4)), answers = Int(try u16(message, 6))
        let authorities = Int(try u16(message, 8)), additional = Int(try u16(message, 10))
        guard questions == 1, answers + authorities + additional <= maximumRecords else { throw DNSResolutionRecordParserError.malformedMessage }
        var offset = 12
        let question = try name(message, offset: &offset)
        guard !question.isEmpty else { throw DNSResolutionRecordParserError.invalidName }
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
                if section == 0, klass == 1, type == qtype {
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
        guard !addresses.isEmpty, offset == message.count else {
            throw DNSResolutionRecordParserError.malformedMessage
        }
        var seen = Set<IPAddress>()
        return DNSResolutionRecord(
            hostname: question,
            addresses: addresses.filter { seen.insert($0).inserted },
            aliases: aliases,
            ttl: ttl == .max ? 0 : ttl
        )
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
                guard pointer < position, visited.insert(pointer).inserted else { throw DNSResolutionRecordParserError.compressionLoop }
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
public final class DNSResolutionAssociationStore: @unchecked Sendable {
    public struct Key: Hashable, Sendable {
        public let sourceIdentity: String
        public let address: IPAddress
        public let configurationRevision: UInt64
        public let generation: UUID

        public init(
            sourceIdentity: String,
            address: IPAddress,
            configurationRevision: UInt64,
            generation: UUID
        ) {
            self.sourceIdentity = sourceIdentity
            self.address = address
            self.configurationRevision = configurationRevision
            self.generation = generation
        }
    }

    private struct Entry: Sendable {
        var expirationsByHostname: [String: Date]
        var touched: UInt64
    }

    private struct State: Sendable {
        var entries: [Key: Entry] = [:]
        var clock: UInt64 = 0
    }

    private let lock = NSLock()
    private var state = State()
    public let maximumEntries: Int
    public let maximumEntriesPerSource: Int
    public let minimumTTL: TimeInterval
    public let maximumTTL: TimeInterval

    public init(
        maximumEntries: Int = 4_096,
        maximumEntriesPerSource: Int = 512,
        minimumTTL: TimeInterval = 5,
        maximumTTL: TimeInterval = 600
    ) {
        self.maximumEntries = max(1, maximumEntries)
        self.maximumEntriesPerSource = max(1, maximumEntriesPerSource)
        self.minimumTTL = max(0, minimumTTL)
        self.maximumTTL = max(self.minimumTTL, maximumTTL)
    }

    public func associate(
        hostname: String,
        addresses: [IPAddress],
        sourceIdentity: String,
        configurationRevision: UInt64,
        generation: UUID,
        ttl: UInt32,
        now: Date = Date()
    ) {
        guard let host = Self.normalizedHostname(hostname),
              let source = Self.normalizedSourceIdentity(sourceIdentity) else {
            return
        }
        lock.withLock {
            if state.entries.count >= maximumEntries || state.clock & 0x3f == 0 {
                purgeExpired(now: now)
            }
            let expiry = now.addingTimeInterval(
                min(max(Double(ttl), minimumTTL), maximumTTL)
            )
            for address in Set(addresses) {
                let key = Key(
                    sourceIdentity: source,
                    address: address,
                    configurationRevision: configurationRevision,
                    generation: generation
                )
                state.clock &+= 1
                var entry = state.entries[key] ?? Entry(
                    expirationsByHostname: [:],
                    touched: state.clock
                )
                entry.expirationsByHostname[host] = max(
                    entry.expirationsByHostname[host] ?? .distantPast,
                    expiry
                )
                entry.touched = state.clock
                state.entries[key] = entry
            }
            enforcePerSourceLimit(sourceIdentity: source)
            enforceGlobalLimit()
        }
    }

    public func hostname(
        for address: IPAddress,
        sourceIdentity: String,
        configurationRevision: UInt64,
        generation: UUID,
        now: Date = Date()
    ) -> String? {
        guard let source = Self.normalizedSourceIdentity(sourceIdentity) else {
            return nil
        }
        return lock.withLock {
            let key = Key(
                sourceIdentity: source,
                address: address,
                configurationRevision: configurationRevision,
                generation: generation
            )
            guard var entry = state.entries[key] else { return nil }
            entry.expirationsByHostname = entry.expirationsByHostname.filter {
                $0.value > now
            }
            guard !entry.expirationsByHostname.isEmpty else {
                state.entries.removeValue(forKey: key)
                return nil
            }
            guard entry.expirationsByHostname.count == 1 else {
                state.entries[key] = entry
                return nil
            }
            state.clock &+= 1
            let touched = state.clock
            entry.touched = touched
            state.entries[key] = entry
            return entry.expirationsByHostname.keys.first
        }
    }

    public func count(now: Date = Date()) -> Int {
        lock.withLock {
            purgeExpired(now: now)
            return state.entries.count
        }
    }

    public func removeAll() {
        lock.withLock {
            state.entries.removeAll(keepingCapacity: true)
            state.clock = 0
        }
    }

    private func purgeExpired(now: Date) {
        for key in Array(state.entries.keys) {
            guard var entry = state.entries[key] else { continue }
            entry.expirationsByHostname = entry.expirationsByHostname.filter {
                $0.value > now
            }
            if entry.expirationsByHostname.isEmpty {
                state.entries.removeValue(forKey: key)
            } else {
                state.entries[key] = entry
            }
        }
    }

    private func enforcePerSourceLimit(sourceIdentity: String) {
        while state.entries.count(where: {
            $0.key.sourceIdentity == sourceIdentity
        }) > maximumEntriesPerSource {
            guard let victim = state.entries
                .filter({ $0.key.sourceIdentity == sourceIdentity })
                .min(by: { $0.value.touched < $1.value.touched })?.key else {
                return
            }
            state.entries.removeValue(forKey: victim)
        }
    }

    private func enforceGlobalLimit() {
        while state.entries.count > maximumEntries {
            guard let victim = state.entries.min(by: {
                $0.value.touched < $1.value.touched
            })?.key else { return }
            state.entries.removeValue(forKey: victim)
        }
    }

    private static func normalizedHostname(_ value: String) -> String? {
        let host = value.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard !host.isEmpty, host.utf8.count <= 253,
              host.unicodeScalars.allSatisfy({ $0.isASCII }),
              host.split(separator: ".", omittingEmptySubsequences: false)
                .allSatisfy({ label in
                    !label.isEmpty && label.utf8.count <= 63
                        && label.utf8.allSatisfy {
                            ($0 >= 0x30 && $0 <= 0x39)
                                || ($0 >= 0x61 && $0 <= 0x7a)
                                || $0 == 0x2d || $0 == 0x5f
                        }
                }) else {
            return nil
        }
        return host
    }

    private static func normalizedSourceIdentity(_ value: String) -> String? {
        let source = value.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !source.isEmpty, source.utf8.count <= 512,
              !source.unicodeScalars.contains(where: {
                  CharacterSet.controlCharacters.contains($0)
              }) else {
            return nil
        }
        return source
    }
}
