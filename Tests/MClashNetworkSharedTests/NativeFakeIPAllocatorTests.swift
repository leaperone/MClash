import Foundation
import Testing
@testable import MClashNetworkShared

@Suite("Native fake IP allocator")
struct NativeFakeIPAllocatorTests {
    @Test("Allocates stable bounded IPv4 mappings and reverses them")
    func stableAndReversible() throws {
        let allocator = try NativeFakeIPAllocator(pool: IPNetwork("198.18.0.0/30"), maximumEntries: 2, minimumTTL: 1, maximumTTL: 10)
        let generation = UUID(); let now = Date(timeIntervalSince1970: 10)
        let real = try IPAddress("203.0.113.7")
        let first = try #require(try allocator.allocate(hostname: "www.example.com", realAddresses: [real], sourceIdentity: "com.example.app", revision: 4, generation: generation, ttl: 30, now: now))
        let second = try #require(try allocator.allocate(hostname: "www.example.com", realAddresses: [try IPAddress("203.0.113.8")], sourceIdentity: "com.example.app", revision: 4, generation: generation, ttl: 30, now: now))
        #expect(first.virtualAddress == second.virtualAddress)
        #expect(second.realAddresses == [try IPAddress("203.0.113.8")])
        #expect(allocator.resolution(for: first.virtualAddress, sourceIdentity: "COM.EXAMPLE.APP", revision: 4, generation: generation, now: now)?.hostname == "www.example.com")
        #expect(allocator.resolution(for: first.virtualAddress, sourceIdentity: "other", revision: 4, generation: generation, now: now) == nil)
        #expect(allocator.resolution(for: first.virtualAddress, sourceIdentity: "com.example.app", revision: 5, generation: generation, now: now) == nil)
        #expect(allocator.resolution(for: first.virtualAddress, sourceIdentity: "com.example.app", revision: 4, generation: UUID(), now: now) == nil)
    }

    @Test("Filters local names and unsafe addresses, and expires mappings")
    func safetyAndExpiry() throws {
        let allocator = try NativeFakeIPAllocator(pool: IPNetwork("198.18.0.0/30"), minimumTTL: 1, maximumTTL: 10, filters: ["+.blocked.example"])
        let generation = UUID(); let real = try IPAddress("192.168.1.1")
        #expect(try allocator.allocate(hostname: "router.lan", realAddresses: [real], sourceIdentity: "app", revision: 1, generation: generation, ttl: 5) == nil)
        #expect(try allocator.allocate(hostname: "x.blocked.example", realAddresses: [try IPAddress("203.0.113.1")], sourceIdentity: "app", revision: 1, generation: generation, ttl: 5) == nil)
        let value = try #require(try allocator.allocate(hostname: "valid.example", realAddresses: [try IPAddress("203.0.113.1")], sourceIdentity: "app", revision: 1, generation: generation, ttl: 1, now: Date(timeIntervalSince1970: 10)))
        #expect(allocator.resolution(for: value.virtualAddress, sourceIdentity: "app", revision: 1, generation: generation, now: Date(timeIntervalSince1970: 12)) == nil)
    }

    @Test("Restricts pools, capacities, filters, hostnames, and identities")
    func validatesConfigurationAndInputs() throws {
        let small = try NativeFakeIPAllocator(pool: IPNetwork("198.18.0.0/30"))
        #expect(small.maximumEntries == 2)
        #expect(small.maximumEntriesPerSource == 2)
        #expect(throws: NativeFakeIPAllocatorError.unsupportedPool) {
            _ = try NativeFakeIPAllocator(pool: IPNetwork("192.168.0.0/24"))
        }
        #expect(throws: NativeFakeIPAllocatorError.unsupportedPool) {
            _ = try NativeFakeIPAllocator(pool: IPNetwork("203.0.113.0/24"))
        }
        #expect(throws: NativeFakeIPAllocatorError.invalidPool) {
            _ = try NativeFakeIPAllocator(
                pool: IPNetwork("198.18.0.0/30"),
                maximumEntries: 3
            )
        }
        #expect(throws: NativeFakeIPAllocatorError.invalidPool) {
            _ = try NativeFakeIPAllocator(maximumTTL: 601)
        }
        #expect(throws: NativeFakeIPAllocatorError.invalidFilter) {
            _ = try NativeFakeIPAllocator(filters: ["bad filter.example"])
        }

        let allocator = try NativeFakeIPAllocator(
            pool: IPNetwork("198.18.0.0/28"),
            filters: ["exact.example", "*.wild.example", "+.suffix.example"]
        )
        let real = try IPAddress("203.0.113.1")
        let generation = UUID()
        #expect(try allocator.allocate(hostname: "exact.example", realAddresses: [real], sourceIdentity: "app", revision: 1, generation: generation, ttl: 30) == nil)
        #expect(try allocator.allocate(hostname: "child.exact.example", realAddresses: [real], sourceIdentity: "app", revision: 1, generation: generation, ttl: 30) != nil)
        #expect(try allocator.allocate(hostname: "wild.example", realAddresses: [real], sourceIdentity: "app", revision: 1, generation: generation, ttl: 30) != nil)
        #expect(try allocator.allocate(hostname: "child.wild.example", realAddresses: [real], sourceIdentity: "app", revision: 1, generation: generation, ttl: 30) == nil)
        #expect(try allocator.allocate(hostname: "suffix.example", realAddresses: [real], sourceIdentity: "app", revision: 1, generation: generation, ttl: 30) == nil)
        #expect(try allocator.allocate(hostname: "child.suffix.example", realAddresses: [real], sourceIdentity: "app", revision: 1, generation: generation, ttl: 30) == nil)
        #expect(throws: NativeFakeIPAllocatorError.invalidHostname) {
            _ = try allocator.allocate(hostname: "bad host", realAddresses: [real], sourceIdentity: "app", revision: 1, generation: generation, ttl: 30)
        }
        #expect(throws: NativeFakeIPAllocatorError.invalidHostname) {
            _ = try allocator.allocate(hostname: "valid.example", realAddresses: [real], sourceIdentity: "bad\nidentity", revision: 1, generation: generation, ttl: 30)
        }
    }

    @Test("Deduplicates and bounds real addresses on allocation and refresh")
    func boundsRealAddresses() throws {
        let allocator = try NativeFakeIPAllocator(pool: IPNetwork("198.18.0.0/28"))
        let generation = UUID()
        let addresses = try (1...20).map { try IPAddress("203.0.113.\($0)") }
        let first = try #require(try allocator.allocate(
            hostname: "many.example",
            realAddresses: addresses + addresses,
            sourceIdentity: "app",
            revision: 1,
            generation: generation,
            ttl: 30
        ))
        #expect(first.realAddresses.count == 16)
        #expect(Set(first.realAddresses).count == 16)
        let refreshed = try #require(try allocator.allocate(
            hostname: "many.example",
            realAddresses: Array(addresses.reversed()) + Array(addresses.reversed()),
            sourceIdentity: "app",
            revision: 1,
            generation: generation,
            ttl: 30
        ))
        #expect(refreshed.virtualAddress == first.virtualAddress)
        #expect(refreshed.realAddresses.count == 16)
        #expect(Set(refreshed.realAddresses).count == 16)
    }

    @Test("Applies per-source and global deterministic LRU bounds")
    func lruBounds() throws {
        let allocator = try NativeFakeIPAllocator(pool: IPNetwork("198.18.0.0/29"), maximumEntries: 3, maximumEntriesPerSource: 2, minimumTTL: 1, maximumTTL: 60)
        let generation = UUID(); let now = Date(timeIntervalSince1970: 1)
        func address(_ octet: UInt8) throws -> IPAddress { try IPAddress("203.0.113.\(octet)") }
        let first = try #require(try allocator.allocate(hostname: "one.example", realAddresses: [try address(1)], sourceIdentity: "a", revision: 1, generation: generation, ttl: 30, now: now))
        let second = try #require(try allocator.allocate(hostname: "two.example", realAddresses: [try address(2)], sourceIdentity: "a", revision: 1, generation: generation, ttl: 30, now: now.addingTimeInterval(1)))
        _ = allocator.resolution(for: first.virtualAddress, sourceIdentity: "a", revision: 1, generation: generation, now: now.addingTimeInterval(2))
        let third = try #require(try allocator.allocate(hostname: "three.example", realAddresses: [try address(3)], sourceIdentity: "a", revision: 1, generation: generation, ttl: 30, now: now.addingTimeInterval(3)))
        #expect(allocator.count(now: now.addingTimeInterval(3)) == 2)
        #expect(allocator.resolution(for: first.virtualAddress, sourceIdentity: "a", revision: 1, generation: generation, now: now.addingTimeInterval(3)) != nil)
        #expect(allocator.resolution(for: second.virtualAddress, sourceIdentity: "a", revision: 1, generation: generation, now: now.addingTimeInterval(3)) == nil)
        let fourth = try #require(try allocator.allocate(hostname: "four.example", realAddresses: [try address(4)], sourceIdentity: "b", revision: 1, generation: generation, ttl: 30, now: now.addingTimeInterval(4)))
        #expect(allocator.count(now: now.addingTimeInterval(4)) == 3)
        let fifth = try #require(try allocator.allocate(hostname: "five.example", realAddresses: [try address(5)], sourceIdentity: "b", revision: 1, generation: generation, ttl: 30, now: now.addingTimeInterval(5)))
        #expect(allocator.count(now: now.addingTimeInterval(5)) == 3)
        #expect(allocator.resolution(for: first.virtualAddress, sourceIdentity: "a", revision: 1, generation: generation, now: now.addingTimeInterval(5)) != nil)
        #expect(allocator.resolution(for: third.virtualAddress, sourceIdentity: "a", revision: 1, generation: generation, now: now.addingTimeInterval(5)) == nil)
        #expect(allocator.resolution(for: fourth.virtualAddress, sourceIdentity: "b", revision: 1, generation: generation, now: now.addingTimeInterval(5)) != nil)
        #expect(allocator.resolution(for: fifth.virtualAddress, sourceIdentity: "b", revision: 1, generation: generation, now: now.addingTimeInterval(5)) != nil)
    }
}
