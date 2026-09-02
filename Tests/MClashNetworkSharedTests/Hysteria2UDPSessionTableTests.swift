import Foundation
import Testing
@testable import MClashNetworkShared

@Suite("Hysteria2 UDP session table")
struct Hysteria2UDPSessionTableTests {
    @Test("Allocates monotonic packet IDs and refreshes session activity")
    func packetIDs() {
        var table = Hysteria2UDPSessionTable()
        let now = Date()
        #expect(table.allocatePacketID(for: 42, now: now) == 0)
        #expect(table.allocatePacketID(for: 42, now: now.addingTimeInterval(1)) == 1)
        #expect(table.touch(42, now: now.addingTimeInterval(2))?.lastSeenAt == now.addingTimeInterval(2))
    }

    @Test("Expires idle sessions and enforces capacity")
    func expirationAndCapacity() {
        var table = Hysteria2UDPSessionTable(maximumSessions: 1, expiration: 1)
        let now = Date()
        #expect(table.touch(1, now: now) != nil)
        #expect(table.touch(2, now: now) == nil)
        table.prune(now: now.addingTimeInterval(2))
        #expect(table.touch(2, now: now.addingTimeInterval(2)) != nil)
    }
}
