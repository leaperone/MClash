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
        let first = try #require(allocator.allocate(hostname: "www.example.com", realAddresses: [real], sourceIdentity: "com.example.app", revision: 4, generation: generation, ttl: 30, now: now))
        let second = try #require(allocator.allocate(hostname: "www.example.com", realAddresses: [try IPAddress("203.0.113.8")], sourceIdentity: "com.example.app", revision: 4, generation: generation, ttl: 30, now: now))
        #expect(first.virtualAddress == second.virtualAddress)
        #expect(second.realAddresses == [try IPAddress("203.0.113.8")])
        #expect(allocator.resolution(for: first.virtualAddress, sourceIdentity: "COM.EXAMPLE.APP", revision: 4, generation: generation, now: now)?.hostname == "www.example.com")
        #expect(allocator.resolution(for: first.virtualAddress, sourceIdentity: "other", revision: 4, generation: generation, now: now) == nil)
    }

    @Test("Filters local names and unsafe addresses, and expires mappings")
    func safetyAndExpiry() throws {
        let allocator = try NativeFakeIPAllocator(pool: IPNetwork("198.18.0.0/30"), minimumTTL: 1, maximumTTL: 10, filters: ["+.blocked.example"])
        let generation = UUID(); let real = try IPAddress("192.168.1.1")
        #expect(try allocator.allocate(hostname: "router.lan", realAddresses: [real], sourceIdentity: "app", revision: 1, generation: generation, ttl: 5) == nil)
        #expect(try allocator.allocate(hostname: "x.blocked.example", realAddresses: [try IPAddress("203.0.113.1")], sourceIdentity: "app", revision: 1, generation: generation, ttl: 5) == nil)
        let value = try #require(allocator.allocate(hostname: "valid.example", realAddresses: [try IPAddress("203.0.113.1")], sourceIdentity: "app", revision: 1, generation: generation, ttl: 1, now: Date(timeIntervalSince1970: 10)))
        #expect(allocator.resolution(for: value.virtualAddress, sourceIdentity: "app", revision: 1, generation: generation, now: Date(timeIntervalSince1970: 12)) == nil)
    }
}
