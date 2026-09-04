import Foundation

public enum NativeFakeIPAllocatorError: Error, Equatable, Sendable {
    case invalidPool
    case unsupportedPool
    case capacityExceeded
    case invalidHostname
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
    public static let defaultPool: IPNetwork = try! IPNetwork("198.18.0.0/16")
    public static let defaultMaximumEntries = 16_384

    private struct Key: Hashable { let source: String; let hostname: String; let revision: UInt64; let generation: UUID }
    private struct Entry { var resolution: NativeFakeIPResolution; var touched: UInt64 }
    private let lock = NSLock()
    public let pool: IPNetwork
    public let maximumEntries: Int
    public let minimumTTL: TimeInterval
    public let maximumTTL: TimeInterval
    private let filters: [String]
    private var entries: [Key: Entry] = [:]
    private var reverse: [IPAddress: Key] = [:]
    private var next: UInt32
    private var clock: UInt64 = 0

    public init(pool: IPNetwork = NativeFakeIPAllocator.defaultPool, maximumEntries: Int = NativeFakeIPAllocator.defaultMaximumEntries,
                minimumTTL: TimeInterval = 5, maximumTTL: TimeInterval = 600,
                filters: [String] = []) throws {
        guard pool.address.family == .ipv4, (16...30).contains(pool.prefixLength) else {
            throw NativeFakeIPAllocatorError.unsupportedPool
        }
        guard maximumEntries > 0, maximumEntries <= 65_534,
              maximumTTL >= minimumTTL, minimumTTL >= 0 else {
            throw NativeFakeIPAllocatorError.invalidPool
        }
        self.pool = pool; self.maximumEntries = maximumEntries
        self.minimumTTL = minimumTTL; self.maximumTTL = maximumTTL
        self.filters = filters.compactMap(Self.normalizeFilter)
        self.next = Self.number(pool.address) + 1
    }

    public func allocate(hostname: String, realAddresses: [IPAddress], sourceIdentity: String,
                         revision: UInt64, generation: UUID, ttl: UInt32,
                         now: Date = Date()) throws -> NativeFakeIPResolution? {
        guard let host = Self.normalizeHostname(hostname), !Self.isExcluded(host, filters: filters),
              let source = Self.normalizeSource(sourceIdentity) else { throw NativeFakeIPAllocatorError.invalidHostname }
        let addresses = realAddresses.filter { $0.family == .ipv4 && !$0.isLocalNetwork && !$0.isMulticast && !$0.isUnspecified }
        guard !addresses.isEmpty else { return nil }
        return lock.withLock {
            purge(now)
            let key = Key(source: source, hostname: host, revision: revision, generation: generation)
            let expiry = now.addingTimeInterval(min(max(Double(ttl), minimumTTL), maximumTTL))
            if var existing = entries[key], existing.resolution.expiresAt > now {
                let value = NativeFakeIPResolution(virtualAddress: existing.resolution.virtualAddress, hostname: host,
                    realAddresses: addresses, expiresAt: max(existing.resolution.expiresAt, expiry), sourceIdentity: source,
                    revision: revision, generation: generation)
                clock &+= 1; existing.resolution = value; existing.touched = clock; entries[key] = existing
                return value
            }
            guard entries.count < maximumEntries || evictOne() else { return nil }
            guard let address = nextAddress() else { return nil }
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
            purge(now)
            let key = Key(source: source, hostname: "", revision: revision, generation: generation)
            guard let actual = reverse[address], actual.source == key.source,
                  actual.revision == key.revision, actual.generation == key.generation,
                  let entry = entries[actual] else { return nil }
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
    private func evictOne() -> Bool {
        guard let victim = entries.min(by: { $0.value.touched < $1.value.touched }) else { return false }
        reverse.removeValue(forKey: victim.value.resolution.virtualAddress); entries.removeValue(forKey: victim.key); return true
    }
    private func purge(_ now: Date) { for (key, entry) in entries where entry.resolution.expiresAt <= now { reverse.removeValue(forKey: entry.resolution.virtualAddress); entries.removeValue(forKey: key) } }
    private static func number(_ address: IPAddress) -> UInt32 { address.bytes.reduce(0) { ($0 << 8) | UInt32($1) } }
    private static func address(_ value: UInt32) -> IPAddress? { try? IPAddress("(value >> 24).(value >> 16 & 255).(value >> 8 & 255).(value & 255)") }
    private static func normalizeHostname(_ value: String) -> String? { let v = value.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")); guard !v.isEmpty, v.utf8.count <= 253, v.unicodeScalars.allSatisfy({ $0.isASCII }) else { return nil }; return v }
    private static func normalizeSource(_ value: String) -> String? { let v = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(); return v.isEmpty ? nil : v }
    private static func normalizeFilter(_ value: String) -> String? { let v = value.lowercased().trimmingCharacters(in: .whitespacesAndNewlines); return v.isEmpty ? nil : v }
    private static func isExcluded(_ host: String, filters: [String]) -> Bool {
        let defaults = ["localhost", ".local", ".lan", ".home.arpa", ".internal", ".arpa"]
        return (defaults + filters).contains { pattern in
            let p = pattern.hasPrefix("*.") ? String(pattern.dropFirst()) : pattern.hasPrefix("+.") ? String(pattern.dropFirst()) : pattern
            return host == p.trimmingCharacters(in: CharacterSet(charactersIn: ".")) || host.hasSuffix(p) && host.dropLast(p.count).last == "."
        }
    }
}
