import Foundation

public struct Hysteria2FragmentReassembler: Sendable {
    public struct Key: Hashable, Sendable {
        public let sessionID: UInt32
        public let packetID: UInt16
    }

    private struct Pending: Sendable {
        let expectedCount: UInt8
        var fragments: [UInt8: Data]
        var bytes: Int
        var updatedAt: Date
    }

    public let maximumPackets: Int
    public let maximumBytes: Int
    public let expiration: TimeInterval
    private var pending: [Key: Pending] = [:]
    private var totalBytes = 0

    public init(maximumPackets: Int = 256, maximumBytes: Int = 4 * 1024 * 1024, expiration: TimeInterval = 10) {
        self.maximumPackets = maximumPackets
        self.maximumBytes = maximumBytes
        self.expiration = expiration
    }

    public mutating func append(_ message: Hysteria2Codec.UDPMessage, now: Date = Date()) -> Data? {
        prune(now: now)
        let key = Key(sessionID: message.sessionID, packetID: message.packetID)
        if message.fragmentCount == 1 { return message.payload }
        guard message.fragmentID < message.fragmentCount else { return nil }
        if pending[key]?.expectedCount != message.fragmentCount {
            if let old = pending.removeValue(forKey: key) { totalBytes -= old.bytes }
        }
        if pending[key] == nil {
            guard pending.count < maximumPackets else { return nil }
            pending[key] = Pending(expectedCount: message.fragmentCount, fragments: [:], bytes: 0, updatedAt: now)
        }
        guard var value = pending[key] else { return nil }
        if value.fragments[message.fragmentID] == nil {
            let projected = totalBytes + message.payload.count
            guard projected <= maximumBytes else { return nil }
            value.fragments[message.fragmentID] = message.payload
            value.bytes += message.payload.count
            totalBytes = projected
        }
        value.updatedAt = now
        pending[key] = value
        guard value.fragments.count == Int(value.expectedCount) else { return nil }
        let payload = (0..<value.expectedCount).compactMap { value.fragments[$0] }
            .reduce(into: Data()) { $0.append($1) }
        pending.removeValue(forKey: key)
        totalBytes -= value.bytes
        return payload
    }

    public mutating func prune(now: Date = Date()) {
        let expired = pending.filter { now.timeIntervalSince($0.value.updatedAt) > expiration }.map(\.key)
        for key in expired {
            if let value = pending.removeValue(forKey: key) { totalBytes -= value.bytes }
        }
    }
}
