import Foundation
import Testing
@testable import MClashNetworkShared

@Suite("DNS resolution attribution")
struct DNSResolutionAssociationStoreTests {
    @Test("Parses owner, compressed CNAME chain, address and TTL")
    func parsesChain() throws {
        var packet = Data([0x12, 0x34, 0x81, 0, 0, 1, 0, 2, 0, 0, 0, 0])
        packet.append(contentsOf: [7]); packet.append(contentsOf: Data("example".utf8)); packet.append(contentsOf: [3]); packet.append(contentsOf: Data("com".utf8)); packet.append(contentsOf: [0, 0, 1, 0, 1])
        packet.append(contentsOf: [0xc0, 0x0c, 0, 5, 0, 1, 0, 0, 0, 20, 0, 8, 5]); packet.append(contentsOf: Data("alias".utf8)); packet.append(contentsOf: [0xc0, 0x0c])
        packet.append(contentsOf: [0xc0, 0x29, 0, 1, 0, 1, 0, 0, 0, 30, 0, 4, 203, 0, 113, 9])
        let record = try DNSResolutionRecordParser.parse(packet)
        #expect(record.hostname == "example.com")
        #expect(record.addresses.map(\.presentation) == ["203.0.113.9"])
        #expect(record.aliases["example.com"] == "alias.example.com")
        #expect(record.ttl == 20)
    }

    @Test("Parses IPv6 answers and rejects a compression loop")
    func parsesIPv6AndRejectsLoop() throws {
        var packet = Data([0xab, 0xcd, 0x81, 0, 0, 1, 0, 1, 0, 0, 0, 0])
        packet.append(contentsOf: [4])
        packet.append(contentsOf: Data("ipv6".utf8))
        packet.append(contentsOf: [7])
        packet.append(contentsOf: Data("example".utf8))
        packet.append(contentsOf: [0, 0, 28, 0, 1])
        packet.append(contentsOf: [0xc0, 0x0c, 0, 28, 0, 1, 0, 0, 0, 60, 0, 16])
        packet.append(contentsOf: [
            0x20, 0x01, 0x0d, 0xb8, 0, 0, 0, 0,
            0, 0, 0, 0, 0, 0, 0, 1,
        ])
        let record = try DNSResolutionRecordParser.parse(packet)
        #expect(record.addresses.map(\.presentation) == ["2001:db8::1"])

        var loop = Data([0xab, 0xcd, 0x81, 0, 0, 1, 0, 0, 0, 0, 0, 0])
        loop.append(contentsOf: [0xc0, 0x0c, 0, 1, 0, 1])
        #expect(throws: DNSResolutionRecordParserError.compressionLoop) {
            _ = try DNSResolutionRecordParser.parse(loop)
        }
    }

    @Test("Rejects an address family that does not match the question")
    func rejectsMismatchedAddressFamily() throws {
        var packet = Data([0xab, 0xcd, 0x81, 0, 0, 1, 0, 1, 0, 0, 0, 0])
        packet.append(contentsOf: [5])
        packet.append(contentsOf: Data("mixed".utf8))
        packet.append(contentsOf: [7])
        packet.append(contentsOf: Data("example".utf8))
        packet.append(contentsOf: [0, 0, 1, 0, 1])
        packet.append(contentsOf: [
            0xc0, 0x0c, 0, 28, 0, 1, 0, 0, 0, 60, 0, 16,
            0x20, 0x01, 0x0d, 0xb8, 0, 0, 0, 0,
            0, 0, 0, 0, 0, 0, 0, 1,
        ])

        #expect(throws: DNSResolutionRecordParserError.malformedMessage) {
            _ = try DNSResolutionRecordParser.parse(packet)
        }
    }

    @Test("Expires, evicts and rejects ambiguous attribution")
    func boundedStore() async throws {
        let store = DNSResolutionAssociationStore(maximumEntries: 2, maximumEntriesPerSource: 2, minimumTTL: 1, maximumTTL: 10)
        let ip = try IPAddress("192.0.2.1")
        let t = Date(timeIntervalSince1970: 100)
        let generation = UUID()
        store.associate(hostname: "one.example", addresses: [ip], sourceIdentity: "capture", configurationRevision: 1, generation: generation, ttl: 20, now: t)
        store.associate(hostname: "two.example", addresses: [ip], sourceIdentity: "capture", configurationRevision: 1, generation: generation, ttl: 2, now: t)
        #expect(store.hostname(for: ip, sourceIdentity: "capture", configurationRevision: 1, generation: generation, now: t) == nil)
        #expect(store.hostname(for: ip, sourceIdentity: "capture", configurationRevision: 1, generation: generation, now: t.addingTimeInterval(3)) == "one.example")
        store.associate(hostname: "three.example", addresses: [try IPAddress("192.0.2.3")], sourceIdentity: "capture", configurationRevision: 1, generation: generation, ttl: 3, now: t)
        #expect(store.count(now: t) <= 2)
        #expect(store.hostname(for: ip, sourceIdentity: "other", configurationRevision: 1, generation: generation, now: t) == nil)
        #expect(store.hostname(for: ip, sourceIdentity: "capture", configurationRevision: 2, generation: generation, now: t) == nil)
    }

    @Test("Rejects unsafe attribution identities and clears explicitly")
    func rejectsUnsafeValuesAndClears() throws {
        let store = DNSResolutionAssociationStore()
        let ip = try IPAddress("198.51.100.7")
        let generation = UUID()
        store.associate(
            hostname: "bad host.example",
            addresses: [ip],
            sourceIdentity: "app.example",
            configurationRevision: 1,
            generation: generation,
            ttl: 60
        )
        store.associate(
            hostname: "safe.example",
            addresses: [ip],
            sourceIdentity: "bad\nidentity",
            configurationRevision: 1,
            generation: generation,
            ttl: 60
        )
        #expect(store.count() == 0)
        store.associate(
            hostname: "safe.example",
            addresses: [ip],
            sourceIdentity: "APP.EXAMPLE",
            configurationRevision: 1,
            generation: generation,
            ttl: 60
        )
        #expect(store.hostname(
            for: ip,
            sourceIdentity: "app.example",
            configurationRevision: 1,
            generation: generation
        ) == "safe.example")
        store.removeAll()
        #expect(store.count() == 0)
    }

    @Test("Isolates generations and applies per-source LRU eviction")
    func isolatesGenerationsAndEvictsLeastRecentlyUsed() throws {
        let store = DNSResolutionAssociationStore(
            maximumEntries: 3,
            maximumEntriesPerSource: 2,
            minimumTTL: 1,
            maximumTTL: 60
        )
        let first = try IPAddress("192.0.2.1")
        let second = try IPAddress("192.0.2.2")
        let third = try IPAddress("192.0.2.3")
        let generation = UUID()
        let otherGeneration = UUID()
        let now = Date(timeIntervalSince1970: 200)

        store.associate(
            hostname: "first.example",
            addresses: [first],
            sourceIdentity: "com.example.app",
            configurationRevision: 7,
            generation: generation,
            ttl: 30,
            now: now
        )
        store.associate(
            hostname: "second.example",
            addresses: [second],
            sourceIdentity: "com.example.app",
            configurationRevision: 7,
            generation: generation,
            ttl: 30,
            now: now
        )
        #expect(store.hostname(
            for: first,
            sourceIdentity: "com.example.app",
            configurationRevision: 7,
            generation: generation,
            now: now
        ) == "first.example")
        store.associate(
            hostname: "third.example",
            addresses: [third],
            sourceIdentity: "com.example.app",
            configurationRevision: 7,
            generation: generation,
            ttl: 30,
            now: now
        )

        #expect(store.hostname(
            for: first,
            sourceIdentity: "com.example.app",
            configurationRevision: 7,
            generation: generation,
            now: now
        ) == "first.example")
        #expect(store.hostname(
            for: second,
            sourceIdentity: "com.example.app",
            configurationRevision: 7,
            generation: generation,
            now: now
        ) == nil)
        #expect(store.hostname(
            for: third,
            sourceIdentity: "com.example.app",
            configurationRevision: 7,
            generation: generation,
            now: now
        ) == "third.example")
        #expect(store.hostname(
            for: first,
            sourceIdentity: "com.example.app",
            configurationRevision: 7,
            generation: otherGeneration,
            now: now
        ) == nil)
    }
}
