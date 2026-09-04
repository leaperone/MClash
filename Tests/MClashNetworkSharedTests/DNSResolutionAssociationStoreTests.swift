import Foundation
import Testing
@testable import MClashNetworkShared

@Suite("DNS resolution attribution")
struct DNSResolutionAssociationStoreTests {
    @Test("Parses owner, compressed CNAME chain, address and TTL")
    func parsesChain() throws {
        var packet = Data([0x12, 0x34, 0x81, 0, 0, 1, 0, 2, 0, 0, 0, 0])
        packet.append(contentsOf: [7]); packet.append(contentsOf: Data("example".utf8)); packet.append(contentsOf: [3]); packet.append(contentsOf: Data("com".utf8)); packet.append(contentsOf: [0, 0, 1, 0, 1])
        packet.append(contentsOf: [0xc0, 0x0c, 0, 5, 0, 1, 0, 0, 0, 20, 0, 7, 5]); packet.append(contentsOf: Data("alias".utf8)); packet.append(contentsOf: [0xc0, 0x0c])
        packet.append(contentsOf: [0xc0, 0x2a, 0, 1, 0, 1, 0, 0, 0, 30, 0, 4, 203, 0, 113, 9])
        let record = try DNSResolutionRecordParser.parse(packet)
        #expect(record.hostname == "example.com")
        #expect(record.addresses.map(\.presentation) == ["203.0.113.9"])
        #expect(record.aliases["example.com"] == "alias.example.com")
        #expect(record.ttl == 20)
    }

    @Test("Expires, evicts and rejects ambiguous attribution")
    func boundedStore() async throws {
        let store = DNSResolutionAssociationStore(maximumEntries: 2, maximumEntriesPerSource: 2, minimumTTL: 1, maximumTTL: 10)
        let ip = try IPAddress("192.0.2.1")
        let t = Date(timeIntervalSince1970: 100)
        await store.associate(hostname: "one.example", addresses: [ip], sourceIdentity: "capture", configurationRevision: 1, generation: 1, ttl: 20, now: t)
        await store.associate(hostname: "two.example", addresses: [ip], sourceIdentity: "capture", configurationRevision: 1, generation: 1, ttl: 2, now: t)
        #expect(await store.hostname(for: ip, sourceIdentity: "capture", configurationRevision: 1, generation: 1, now: t) == nil)
        #expect(await store.hostname(for: ip, sourceIdentity: "capture", configurationRevision: 1, generation: 1, now: t.addingTimeInterval(3)) == nil)
        await store.associate(hostname: "three.example", addresses: [try IPAddress("192.0.2.3")], sourceIdentity: "capture", configurationRevision: 1, generation: 1, ttl: 3, now: t)
        #expect(await store.count(now: t) <= 2)
    }
}
