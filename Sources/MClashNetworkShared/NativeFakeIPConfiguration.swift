import Foundation

public enum NativeFakeIPConfigurationError: Error, Equatable, Sendable {
    case unsupportedPool
    case invalidCapacity
    case invalidTTL
    case invalidFilter
    case tooManyFilters
}

public enum NativeFakeIPMappingScope: String, Codable, Equatable, Sendable {
    case runtimeGlobal
}

/// Bounded, connector-neutral Fake-IP policy. It contains no runtime mapping
/// state and is safe to cross the Network Extension bootstrap boundary.
public struct NativeFakeIPConfiguration: Codable, Equatable, Sendable {
    public static let maximumFilters = 1_024
    public static let maximumFilterBytes = 253
    public static let maximumEntries = 16_384
    public static let maximumEntriesPerSource = 2_048
    public static let maximumTTL: TimeInterval = 600

    public let pool: IPNetwork
    public let filters: [String]
    public let maximumEntriesCount: Int
    public let maximumEntriesPerSourceCount: Int
    public let minimumTTL: TimeInterval
    public let maximumTTLValue: TimeInterval
    public let mappingScope: NativeFakeIPMappingScope

    public init(pool: IPNetwork? = nil, filters: [String] = [], maximumEntries: Int = Self.maximumEntries,
                maximumEntriesPerSource: Int = Self.maximumEntriesPerSource, minimumTTL: TimeInterval = 5,
                maximumTTL: TimeInterval = NativeFakeIPConfiguration.maximumTTL,
                mappingScope: NativeFakeIPMappingScope = .runtimeGlobal) throws {
        let selectedPool: IPNetwork
        if let pool { selectedPool = pool } else { selectedPool = try IPNetwork("198.18.0.0/16") }
        guard selectedPool.address.family == .ipv4, (15...30).contains(selectedPool.prefixLength),
              Self.number(selectedPool.address) >= Self.number(try! IPAddress("198.18.0.0")),
              Self.poolEnd(selectedPool) <= Self.number(try! IPAddress("198.19.255.255")) else {
            throw NativeFakeIPConfigurationError.unsupportedPool
        }
        guard maximumEntries > 0, maximumEntries <= Self.maximumEntries,
              maximumEntriesPerSource > 0, maximumEntriesPerSource <= Self.maximumEntriesPerSource,
              maximumEntriesPerSource <= maximumEntries else { throw NativeFakeIPConfigurationError.invalidCapacity }
        guard minimumTTL.isFinite, maximumTTL.isFinite, minimumTTL >= 0,
              maximumTTL >= minimumTTL, maximumTTL <= Self.maximumTTL else { throw NativeFakeIPConfigurationError.invalidTTL }
        guard filters.count <= Self.maximumFilters else { throw NativeFakeIPConfigurationError.tooManyFilters }
        let normalized = try filters.map(Self.normalizeFilter)
        self.pool = selectedPool; self.filters = Array(Set(normalized)).sorted()
        self.maximumEntriesCount = maximumEntries; self.maximumEntriesPerSourceCount = maximumEntriesPerSource
        self.minimumTTL = minimumTTL; self.maximumTTLValue = maximumTTL
        self.mappingScope = mappingScope
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let pool = try IPNetwork(c.decode(String.self, forKey: .pool))
        try self.init(pool: pool, filters: c.decodeIfPresent([String].self, forKey: .filters) ?? [],
                      maximumEntries: c.decodeIfPresent(Int.self, forKey: .maximumEntries) ?? Self.maximumEntries,
                      maximumEntriesPerSource: c.decodeIfPresent(Int.self, forKey: .maximumEntriesPerSource) ?? Self.maximumEntriesPerSource,
                      minimumTTL: c.decodeIfPresent(TimeInterval.self, forKey: .minimumTTL) ?? 5,
                      maximumTTL: c.decodeIfPresent(TimeInterval.self, forKey: .maximumTTL) ?? Self.maximumTTL,
                      mappingScope: c.decodeIfPresent(NativeFakeIPMappingScope.self, forKey: .mappingScope) ?? .runtimeGlobal)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(pool.presentation, forKey: .pool); try c.encode(filters, forKey: .filters)
        try c.encode(maximumEntriesCount, forKey: .maximumEntries)
        try c.encode(maximumEntriesPerSourceCount, forKey: .maximumEntriesPerSource)
        try c.encode(minimumTTL, forKey: .minimumTTL); try c.encode(maximumTTLValue, forKey: .maximumTTL)
        try c.encode(mappingScope, forKey: .mappingScope)
    }

    private enum CodingKeys: String, CodingKey { case pool, filters, maximumEntries, maximumEntriesPerSource, minimumTTL, maximumTTL, mappingScope }
    private static func number(_ address: IPAddress) -> UInt32 { address.bytes.reduce(0) { ($0 << 8) | UInt32($1) } }
    private static func poolEnd(_ pool: IPNetwork) -> UInt32 { number(pool.address) + (1 << UInt32(32 - pool.prefixLength)) - 1 }
    private static func normalizeFilter(_ raw: String) throws -> String {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !value.isEmpty, value.utf8.count <= maximumFilterBytes,
              value.unicodeScalars.allSatisfy({ $0.isASCII }),
              value.allSatisfy({ $0.isLetter || $0.isNumber || ".-*+_".contains($0) }) else {
            throw NativeFakeIPConfigurationError.invalidFilter
        }
        return value
    }
}
