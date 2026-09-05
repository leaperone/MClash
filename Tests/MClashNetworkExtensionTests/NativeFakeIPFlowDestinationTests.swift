import Foundation
import Testing
@testable import MClashNetworkExtension
import MClashNetworkShared

@Suite("Native fake-IP flow destination")
struct NativeFakeIPFlowDestinationTests {
    @Test("Resolves only mapped 198.18/15 addresses to a real IPv4 target")
    func resolvesMappedAddress() throws {
        let allocator = try NativeFakeIPAllocator(configuration: NativeFakeIPConfiguration())
        let generation = UUID()
        let real = try IPAddress("203.0.113.10")
        let resolution = try allocator.allocate(
            hostname: "example.com",
            realAddresses: [real],
            sourceIdentity: "com.example.app",
            revision: 4,
            generation: generation,
            ttl: 60
        )
        let fake = try #require(resolution?.virtualAddress.presentation)
        let result = NativeFakeIPFlowDestinationResolver.resolve(
            endpoint: FlowRemoteEndpoint(host: fake, port: 443),
            sourceIdentity: "com.example.app",
            revision: 4,
            generation: generation,
            allocator: allocator
        )
        #expect(result == .resolved(
            endpoint: FlowRemoteEndpoint(host: real.presentation, port: 443),
            hostname: "example.com"
        ))
        #expect(NativeFakeIPFlowDestinationResolver.isFakeIP(try IPAddress("198.18.0.1")))
        #expect(NativeFakeIPFlowDestinationResolver.isFakeIP(try IPAddress("198.19.255.254")))
        #expect(!NativeFakeIPFlowDestinationResolver.isFakeIP(try IPAddress("198.20.0.1")))
    }

    @Test("Unmapped, stale-generation, and non-fake addresses never become connector targets")
    func rejectsUnmappedAndStale() throws {
        let allocator = try NativeFakeIPAllocator(configuration: NativeFakeIPConfiguration())
        let generation = UUID()
        let real = try IPAddress("203.0.113.20")
        let resolution = try allocator.allocate(
            hostname: "example.com", realAddresses: [real], sourceIdentity: "com.example.app",
            revision: 4, generation: generation, ttl: 1
        )
        let fake = try #require(resolution?.virtualAddress.presentation)
        #expect(NativeFakeIPFlowDestinationResolver.resolve(
            endpoint: FlowRemoteEndpoint(host: fake, port: 443), sourceIdentity: "other.app",
            revision: 4, generation: generation, allocator: allocator
        ) == .resolved(
            endpoint: FlowRemoteEndpoint(host: real.presentation, port: 443),
            hostname: "example.com"
        ))
        #expect(NativeFakeIPFlowDestinationResolver.resolve(
            endpoint: FlowRemoteEndpoint(host: fake, port: 443), sourceIdentity: "com.example.app",
            revision: 5, generation: generation, allocator: allocator
        ) == .unavailable)
        #expect(NativeFakeIPFlowDestinationResolver.resolve(
            endpoint: FlowRemoteEndpoint(host: fake, port: 443), sourceIdentity: "com.example.app",
            revision: 4, generation: UUID(), allocator: allocator
        ) == .unavailable)
        #expect(NativeFakeIPFlowDestinationResolver.resolve(
            endpoint: FlowRemoteEndpoint(host: "203.0.113.20", port: 443), sourceIdentity: "com.example.app",
            revision: 4, generation: generation, allocator: allocator
        ) == .notFakeIP)
        #expect(NativeFakeIPFlowDestinationResolver.unavailableDecision().disposition == .reject)
    }
}
