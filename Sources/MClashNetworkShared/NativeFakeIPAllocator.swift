import Foundation

public enum NativeFakeIPAllocatorError: Error, Equatable, Sendable {
    case invalidPool
    case unsupportedPool
    case capacityExceeded
    case invalidHostname
    case invalidFilter
}

public struct NativeFakeIPResolution: Sendable, Equatable {
    public let virtualAddress: IPAddress
    public let hostname: String
    public let realAddresses: [IPAddress]
    public let expiresAt: Date
    public let sourceIdentity: String
    public let revision: UInt64
    public let generation: UUID
}

/// Memory-only IPv4 fake-IP allocator. Mappings are scoped to the source,
/// capture revision and generation so an address can never outlive the policy
/// that created it.
public final class NativeFakeIPAllocator: @unchecked Sendable {
    public static let defaultPoolCIDR = "198.18.0.0/16"
    public static let defaultMaximumEntries = 16_384
    public static let defaultMaximumEntriesPerSource = 2_048

    struct Key: Hashable {
        let source: String
        let hostname: String
        let revision: UInt64
        let generation: UUID
    }
    private struct Entry {
        var resolution: NativeFakeIPResolution
        var touched: UInt64
    }
    private let lock = NSLock()
    public let pool: IPNetwork
    public let maximumEntries: Int
    public let maximumEntriesPerSource: Int
    public let minimumTTL: TimeInterval
    public let maximumTTL: TimeInterval
    private enum FilterKind {
        case exact
        case suffix
        case wildcard
    }

    private struct FilterPattern {
        let kind: FilterKind
        let hostname: String

        func matches(_ candidate: String) -> Bool {
            switch kind {
            case .exact:
                candidate == hostname
            case .suffix:
                candidate == hostname || candidate.hasSuffix("." + hostname)
            case .wildcard:
                candidate != hostname && candidate.hasSuffix("." + hostname)
            }
        }
    }

    private let filters: [FilterPattern]
    private var entries: [Key: Entry] = [:]
    private var reverse: [IPAddress: Key] = [:]
    private var next: UInt32
    private var clock: UInt64 = 0

    public init(pool: IPNetwork? = nil, maximumEntries: Int? = nil,
                maximumEntriesPerSource: Int? = nil,
                minimumTTL: TimeInterval = 5, maximumTTL: TimeInterval = 600,
                filters: [String] = []) throws {
        let configuredPool: IPNetwork
        if let pool { configuredPool = pool } else { configuredPool = try IPNetwork(NativeFakeIPAllocator.defaultPoolCIDR) }
        guard configuredPool.address.family == .ipv4, (15...30).contains(configuredPool.prefixLength),
              Self.number(configuredPool.address) >= Self.number(try! IPAddress("198.18.0.0")),
              Self.poolEnd(configuredPool) <= Self.number(try! IPAddress("198.19.255.255")) else {
            throw NativeFakeIPAllocatorError.unsupportedPool
        }
        let usable = Self.usableCapacity(configuredPool)
        let configuredMaximumEntries = maximumEntries
            ?? min(Self.defaultMaximumEntries, usable)
        let configuredMaximumEntriesPerSource = maximumEntriesPerSource
            ?? min(Self.defaultMaximumEntriesPerSource, configuredMaximumEntries)
        guard configuredMaximumEntries > 0,
              configuredMaximumEntries <= min(Self.defaultMaximumEntries, usable),
              configuredMaximumEntriesPerSource > 0,
              configuredMaximumEntriesPerSource <= min(
                  Self.defaultMaximumEntriesPerSource,
                  configuredMaximumEntries
              ),
              minimumTTL.isFinite, maximumTTL.isFinite,
              minimumTTL >= 0, maximumTTL >= minimumTTL,
              maximumTTL <= 600 else {
            throw NativeFakeIPAllocatorError.invalidPool
        }
        guard filters.count <= 1_024 else {
            throw NativeFakeIPAllocatorError.invalidFilter
        }
        self.pool = configuredPool
        self.maximumEntries = configuredMaximumEntries
        self.maximumEntriesPerSource = configuredMaximumEntriesPerSource
        self.minimumTTL = minimumTTL; self.maximumTTL = maximumTTL
        self.filters = try filters.map(Self.filterPattern)
        self.next = Self.number(configuredPool.address) + 1
    }

    public func allocate(hostname: String, realAddresses: [IPAddress], sourceIdentity: String,
                         revision: UInt64, generation: UUID, ttl: UInt32,
                         now: Date = Date()) throws -> NativeFakeIPResolution? {
        guard let host = Self.normalizeHostname(hostname), let source = Self.normalizeSource(sourceIdentity) else { throw NativeFakeIPAllocatorError.invalidHostname }
        guard !Self.isExcluded(host, filters: filters) else { return nil }
        var seenAddresses = Set<IPAddress>()
        var addresses: [IPAddress] = []
        for address in realAddresses where address.family == .ipv4
            && !address.isLocalNetwork
            && !address.isMulticast
            && !address.isUnspecified
            && seenAddresses.insert(address).inserted {
            addresses.append(address)
            if addresses.count == 16 { break }
        }
        guard !addresses.isEmpty else { return nil }
        return try lock.withLock {
            if entries.count >= maximumEntries || clock & 0x3f == 0 {
                purge(now)
            }
            let key = Key(source: source, hostname: host, revision: revision, generation: generation)
            let expiry = now.addingTimeInterval(min(max(Double(ttl), minimumTTL), maximumTTL))
            if var existing = entries[key], existing.resolution.expiresAt > now {
                let value = NativeFakeIPResolution(virtualAddress: existing.resolution.virtualAddress, hostname: host,
                    realAddresses: addresses, expiresAt: max(existing.resolution.expiresAt, expiry), sourceIdentity: source,
                    revision: revision, generation: generation)
                clock &+= 1; existing.resolution = value; existing.touched = clock; entries[key] = existing
                return value
            }
            removeEntry(for: key)
            if entries.keys.count(where: { $0.source == source }) >= maximumEntriesPerSource,
               !evictOldest(source: source) {
                throw NativeFakeIPAllocatorError.capacityExceeded
            }
            if entries.count >= maximumEntries, !evictOldest(source: nil) {
                throw NativeFakeIPAllocatorError.capacityExceeded
            }
            guard let address = nextAddress() else {
                throw NativeFakeIPAllocatorError.capacityExceeded
            }
            let value = NativeFakeIPResolution(virtualAddress: address, hostname: host, realAddresses: addresses,
                expiresAt: expiry, sourceIdentity: source, revision: revision, generation: generation)
            clock &+= 1; entries[key] = Entry(resolution: value, touched: clock); reverse[address] = key
            return value
        }
    }

    public func resolution(for address: IPAddress, sourceIdentity: String, revision: UInt64,
                           generation: UUID, now: Date = Date()) -> NativeFakeIPResolution? {
        guard let source = Self.normalizeSource(sourceIdentity) else { return nil }
        return lock.withLock {
            let key = Key(source: source, hostname: "", revision: revision, generation: generation)
            guard let actual = reverse[address], actual.source == key.source,
                  actual.revision == key.revision, actual.generation == key.generation,
                  let entry = entries[actual] else { return nil }
            guard entry.resolution.expiresAt > now else {
                removeEntry(for: actual)
                return nil
            }
            clock &+= 1; entries[actual]?.touched = clock; return entry.resolution
        }
    }

    public func removeAll() { lock.withLock { entries.removeAll(); reverse.removeAll(); next = Self.number(pool.address) + 1; clock = 0 } }
    public func count(now: Date = Date()) -> Int { lock.withLock { purge(now); return entries.count } }

    private func nextAddress() -> IPAddress? {
        let first = Self.number(pool.address) + 1
        let size: UInt32 = 1 << UInt32(32 - pool.prefixLength)
        for _ in 0..<size {
            let candidate = next; next = next >= Self.number(pool.address) + size - 2 ? first : next + 1
            guard let address = Self.address(candidate), pool.contains(address), reverse[address] == nil else { continue }
            return address
        }
        return nil
    }
    private func evictOldest(source: String?) -> Bool {
        let candidates = source.map { requestedSource in
            entries.filter { $0.key.source == requestedSource }
        } ?? entries
        let victim = candidates.min(by: { $0.value.touched < $1.value.touched })
        guard let victim else { return false }
        removeEntry(for: victim.key)
        return true
    }
    private func removeEntry(for key: Key) {
        guard let removed = entries.removeValue(forKey: key) else { return }
        reverse.removeValue(forKey: removed.resolution.virtualAddress)
    }
    private func purge(_ now: Date) {
        for key in Array(entries.keys) {
            guard let entry = entries[key], entry.resolution.expiresAt <= now else {
                continue
            }
            removeEntry(for: key)
        }
    }
    private static func number(_ address: IPAddress) -> UInt32 { address.bytes.reduce(0) { ($0 << 8) | UInt32($1) } }
    private static func address(_ value: UInt32) -> IPAddress? { try? IPAddress("\(value >> 24).\(value >> 16 & 255).\(value >> 8 & 255).\(value & 255)") }
    private static func poolEnd(_ pool: IPNetwork) -> UInt32 { number(pool.address) + (1 << UInt32(32 - pool.prefixLength)) - 1 }
    private static func usableCapacity(_ pool: IPNetwork) -> Int { Int((1 << UInt32(32 - pool.prefixLength)) - 2) }
    private static func normalizeHostname(_ value: String) -> String? {
        let v = value.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        let labels = v.split(separator: ".", omittingEmptySubsequences: false)
        guard !v.isEmpty, v.utf8.count <= 253,
              labels.allSatisfy({ label in
                  !label.isEmpty && label.utf8.count <= 63 && label.utf8.allSatisfy {
                      $0 == 0x2d || $0 == 0x5f
                          || ($0 >= 0x30 && $0 <= 0x39)
                          || ($0 >= 0x61 && $0 <= 0x7a)
                  }
              }) else { return nil }
        return v
    }
    private static func normalizeSource(_ value: String) -> String? { let v = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(); guard !v.isEmpty, v.utf8.count <= 512, !v.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return nil }; return v }
    private static func filterPattern(_ value: String) throws -> FilterPattern {
        let trimmed = value.lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let kind: FilterKind
        let rawHostname: String
        if trimmed.hasPrefix("+.") {
            kind = .suffix
            rawHostname = String(trimmed.dropFirst(2))
        } else if trimmed.hasPrefix("*.") {
            kind = .wildcard
            rawHostname = String(trimmed.dropFirst(2))
        } else if trimmed.hasPrefix(".") {
            kind = .suffix
            rawHostname = String(trimmed.dropFirst())
        } else {
            kind = .exact
            rawHostname = trimmed
        }
        guard let hostname = normalizeHostname(rawHostname) else {
            throw NativeFakeIPAllocatorError.invalidFilter
        }
        return FilterPattern(kind: kind, hostname: hostname)
    }

    private static func isExcluded(_ host: String, filters: [FilterPattern]) -> Bool {
        let defaults = [
            FilterPattern(kind: .exact, hostname: "localhost"),
            FilterPattern(kind: .suffix, hostname: "local"),
            FilterPattern(kind: .suffix, hostname: "lan"),
            FilterPattern(kind: .suffix, hostname: "home.arpa"),
            FilterPattern(kind: .suffix, hostname: "internal"),
            FilterPattern(kind: .suffix, hostname: "arpa"),
        ]
        return (defaults + filters).contains { $0.matches(host) }
    }
}
