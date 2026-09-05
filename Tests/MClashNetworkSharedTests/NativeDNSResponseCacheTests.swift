import Foundation
import Testing
@testable import MClashNetworkShared

@Suite("Native DNS response cache")
struct NativeDNSResponseCacheTests {
    private let query = Data([
        0x12, 0x34, 0x01, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x07, 0x65, 0x78, 0x61, 0x6d, 0x70, 0x6c, 0x65, 0x03, 0x63, 0x6f, 0x6d,
        0x00, 0x00, 0x01, 0x00, 0x01
    ])

    @Test("Restores each request transaction ID")
    func transactionIDIsPerRequest() async {
        let cache = NativeDNSResponseCache()
        var response = query
        response[2] = 0x81
        response[3] = 0x80
        await cache.insert(query: query, response: response)

        var secondQuery = query
        secondQuery[0] = 0xab
        secondQuery[1] = 0xcd
        let cached = await cache.response(for: secondQuery)
        #expect(cached?[0] == 0xab)
        #expect(cached?[1] == 0xcd)
        #expect(cached?.dropFirst(2) == response.dropFirst(2))
    }

    @Test("Evicts oldest entries at the configured capacity")
    func capacityIsBounded() async {
        let cache = NativeDNSResponseCache(capacity: 1)
        var first = query
        first[12] = 0x03
        var second = query
        second[12] = 0x04
        await cache.insert(query: first, response: first)
        await cache.insert(query: second, response: second)
        #expect(await cache.response(for: first) == nil)
        #expect(await cache.response(for: second) != nil)
    }

    @Test("Expired entries are never returned")
    func expirationIsFailClosed() async {
        let cache = NativeDNSResponseCache(ttl: .zero)
        await cache.insert(query: query, response: query)
        #expect(await cache.response(for: query) == nil)
    }
}
