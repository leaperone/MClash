import Foundation

public struct Hysteria2UDPSessionTable: Sendable {
    public struct Session: Equatable, Sendable {
        public let id: UInt32
        public var nextPacketID: UInt16
        public var lastSeenAt: Date
    }

    public let maximumSessions: Int
    public let expiration: TimeInterval
    private var sessions: [UInt32: Session] = [:]

    public init(maximumSessions: Int = 256, expiration: TimeInterval = 120) {
        self.maximumSessions = maximumSessions
        self.expiration = expiration
    }

    public mutating func touch(_ id: UInt32, now: Date = Date()) -> Session? {
        prune(now: now)
        if var session = sessions[id] {
            session.lastSeenAt = now
            sessions[id] = session
            return session
        }
        guard sessions.count < maximumSessions else { return nil }
        let session = Session(id: id, nextPacketID: 0, lastSeenAt: now)
        sessions[id] = session
        return session
    }

    public mutating func allocatePacketID(for id: UInt32, now: Date = Date()) -> UInt16? {
        guard var session = touch(id, now: now) else { return nil }
        let packetID = session.nextPacketID
        session.nextPacketID = session.nextPacketID &+ 1
        session.lastSeenAt = now
        sessions[id] = session
        return packetID
    }

    public mutating func remove(_ id: UInt32) {
        sessions.removeValue(forKey: id)
    }

    public mutating func prune(now: Date = Date()) {
        sessions = sessions.filter { now.timeIntervalSince($0.value.lastSeenAt) <= expiration }
    }
}
