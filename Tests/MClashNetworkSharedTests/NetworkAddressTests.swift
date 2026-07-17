import Foundation
@testable import MClashNetworkShared
import Testing

@Suite("Network addresses and ranges")
struct NetworkAddressTests {
    @Test
    func testIPv4AndIPv6CanonicalRoundTrip() throws {
        let ipv4 = try IPAddress("192.0.2.4")
        #expect(ipv4.family == .ipv4)
        #expect(ipv4.presentation == "192.0.2.4")

        let ipv6 = try IPAddress("2001:0db8:0:0:0:0:0:1")
        #expect(ipv6.family == .ipv6)
        #expect(ipv6.presentation == "2001:db8::1")

        let encoded = try JSONEncoder().encode(ipv6)
        #expect(try JSONDecoder().decode(IPAddress.self, from: encoded) == ipv6)
    }

    @Test
    func testInvalidIPAddressIsRejected() {
        #expect(throws: NetworkRuleValidationError.self) { try IPAddress("300.1.1.1") }
        #expect(throws: NetworkRuleValidationError.self) { try IPAddress("not-an-address") }
    }

    @Test
    func testIPv4NetworkNormalizesHostBitsAndMatches() throws {
        let network = try IPNetwork("192.168.9.77/24")
        #expect(network.presentation == "192.168.9.0/24")
        #expect(network.contains(try IPAddress("192.168.9.255")))
        #expect(!network.contains(try IPAddress("192.168.10.1")))
        #expect(!network.contains(try IPAddress("::ffff:c0a8:0901")))
    }

    @Test
    func testIPv6NetworkMatchesAtNonByteBoundary() throws {
        let network = try IPNetwork("2001:db8:abcd::/49")
        #expect(network.contains(try IPAddress("2001:db8:abcd::1")))
        #expect(!network.contains(try IPAddress("2001:db8:2bcd::1")))
    }

    @Test
    func testZeroLengthPrefixesMatchTheirAddressFamilyOnly() throws {
        #expect(try IPNetwork("0.0.0.0/0").contains(IPAddress("203.0.113.8")))
        #expect(try IPNetwork("::/0").contains(IPAddress("2001:db8::1")))
        #expect(try !IPNetwork("0.0.0.0/0").contains(IPAddress("2001:db8::1")))
    }

    @Test
    func testInvalidCIDRPrefixIsRejectedDuringInitAndDecode() throws {
        #expect(throws: NetworkRuleValidationError.self) { try IPNetwork("192.0.2.0/33") }
        #expect(throws: NetworkRuleValidationError.self) { try IPNetwork("2001:db8::/129") }

        let invalidJSON = Data("\"192.0.2.0/999\"".utf8)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(IPNetwork.self, from: invalidJSON)
        }
    }

    @Test
    func testSpecialAddressClassification() throws {
        #expect(try IPAddress("127.8.9.10").isLoopback)
        #expect(try IPAddress("::1").isLoopback)
        #expect(try IPAddress("169.254.7.8").isLinkLocal)
        #expect(try IPAddress("fe80::1").isLinkLocal)
        #expect(try IPAddress("239.1.1.1").isMulticast)
        #expect(try IPAddress("ff02::1").isMulticast)
        #expect(try IPAddress("0.0.0.0").isUnspecified)
        #expect(try IPAddress("::").isUnspecified)
    }

    @Test
    func testPortRangeBoundariesAndValidation() throws {
        let range = try PortRange(lowerBound: 443, upperBound: 8443)
        #expect(range.contains(443))
        #expect(range.contains(8443))
        #expect(!range.contains(80))
        #expect(throws: NetworkRuleValidationError.self) { try PortRange(0) }
        #expect(throws: NetworkRuleValidationError.self) {
            try PortRange(lowerBound: 9000, upperBound: 8000)
        }

        let invalidJSON = Data(#"{"lowerBound":0,"upperBound":80}"#.utf8)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(PortRange.self, from: invalidJSON)
        }
    }

    @Test
    func testDomainMatcherNormalizesAndDoesNotOvermatchSuffix() throws {
        let exact = try HostMatcher(kind: .exact, value: "API.Example.COM.")
        #expect(exact.matches("api.example.com"))
        #expect(!exact.matches("www.example.com"))

        let suffix = try HostMatcher(kind: .suffix, value: "example.com")
        #expect(suffix.matches("example.com"))
        #expect(suffix.matches("cdn.example.com."))
        #expect(!suffix.matches("notexample.com"))
        #expect(throws: NetworkRuleValidationError.self) {
            try HostMatcher(kind: .exact, value: "bad..example.com")
        }
    }
}
