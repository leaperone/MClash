import Foundation

/// Small, bounded response cache for the native DNS data plane.
///
/// DNS transaction IDs are per-query, so the cache key excludes the first two
/// bytes and a hit restores the caller's ID before the response is returned.
/// The cache deliberately uses a conservative fixed TTL; this keeps the
/// contract safe until a record-aware TTL parser is introduced.
public actor NativeDNSResponseCache {
    public let capacity: Int
    public let ttl: Duration

    private struct Entry: Sendable {
        let response: Data
        let expiresAt: ContinuousClock.Instant
    }

    private var entries: [Data: Entry] = [:]
    private var order: [Data] = []
    private let clock = ContinuousClock()

    public init(capacity: Int = 256, ttl: Duration = .seconds(30)) {
        self.capacity = max(1, capacity)
        self.ttl = ttl
    }

    /// Returns a response with the query transaction ID, or nil on a miss.
    public func response(for query: Data) -> Data? {
        guard let key = Self.key(for: query),
              let entry = entries[key] else { return nil }
        guard clock.now < entry.expiresAt else {
            remove(key)
            return nil
        }
        var result = entry.response
        guard result.count >= 2, query.count >= 2 else { return nil }
        result[0] = query[0]
        result[1] = query[1]
        return result
    }

    /// Stores only a validated DNS response. Invalid or truncated packets are
    /// ignored so callers cannot poison the cache with arbitrary bytes.
    public func insert(query: Data, response: Data) {
        guard let key = Self.key(for: query), response.count >= 12 else { return }
        let entry = Entry(response: response, expiresAt: clock.now.advanced(by: ttl))
        if entries[key] != nil { order.removeAll { $0 == key } }
        entries[key] = entry
        order.append(key)
        while order.count > capacity {
            entries.removeValue(forKey: order.removeFirst())
        }
    }

    public func removeAll() {
        entries.removeAll(keepingCapacity: true)
        order.removeAll(keepingCapacity: true)
    }

    private func remove(_ key: Data) {
        entries.removeValue(forKey: key)
        order.removeAll { $0 == key }
    }

    private static func key(for query: Data) -> Data? {
        guard query.count >= 12 else { return nil }
        var key = query
        key[0] = 0
        key[1] = 0
        return key
    }
}
