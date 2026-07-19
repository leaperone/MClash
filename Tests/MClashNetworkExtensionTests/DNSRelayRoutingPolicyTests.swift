import MClashNetworkShared
import Testing
@testable import MClashNetworkExtension

@Suite("DNS relay routing policy")
struct DNSRelayRoutingPolicyTests {
    @Test("Local router resolvers bypass the private Mihomo listener")
    func localResolverIsDirect() throws {
        #expect(
            DNSRelayRoutingPolicy.route(
                destination: try endpoint("192.168.1.1"),
                isTrustedMClashComponent: false
            ) == .directLocalResolver
        )
        #expect(
            DNSRelayRoutingPolicy.route(
                destination: try endpoint("fd00::53"),
                isTrustedMClashComponent: false
            ) == .directLocalResolver
        )
    }

    @Test("Public resolvers still follow profile routing through Mihomo")
    func publicResolverUsesMihomo() throws {
        #expect(
            DNSRelayRoutingPolicy.route(
                destination: try endpoint("1.1.1.1"),
                isTrustedMClashComponent: false
            ) == .mihomo
        )
    }

    @Test("Trusted MClash DNS egress remains direct")
    func trustedComponentIsDirect() throws {
        #expect(
            DNSRelayRoutingPolicy.route(
                destination: try endpoint("1.1.1.1"),
                isTrustedMClashComponent: true
            ) == .directTrustedComponent
        )
    }

    private func endpoint(_ address: String) throws -> SOCKS5Endpoint {
        SOCKS5Endpoint(address: SOCKS5Address(ipAddress: try IPAddress(address)), port: 53)
    }
}
