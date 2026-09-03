import Foundation
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
            ) == .proxy(.profileRules)
        )
    }

    @Test("Native mode selects the connector-neutral socket upstream")
    func publicResolverUsesNativeUpstreamWhenOptedIn() throws {
        let route = DNSRelayRoutingPolicy.route(
            destination: try endpoint("1.1.1.1"),
            isTrustedMClashComponent: false,
            upstreamMode: .native,
            transport: .tcp,
            nativeBootstrap: try DNSUpstreamBootstrap(endpoints: [
                try DNSUpstreamEndpoint(
                    address: IPAddress("1.1.1.1"),
                    transport: .tcp
                )
            ])
        )
        #expect(route == .native(try DNSUpstreamEndpoint(
            address: IPAddress("1.1.1.1"), port: 53, transport: .tcp
        )))
        #expect(route.bypassesMihomo)
    }

    @Test("Native mode selects the configured bootstrap endpoint")
    func nativeModeUsesBootstrapEndpoint() throws {
        let bootstrap = try DNSUpstreamBootstrap(endpoints: [
            try DNSUpstreamEndpoint(
                address: IPAddress("9.9.9.9"), port: 853,
                transport: .tcp
            ),
            try DNSUpstreamEndpoint(
                address: IPAddress("1.1.1.1"), port: 53,
                transport: .udp
            ),
        ])
        let route = DNSRelayRoutingPolicy.route(
            destination: try endpoint("192.0.2.1"),
            isTrustedMClashComponent: false,
            upstreamMode: .native,
            transport: .tcp,
            nativeBootstrap: bootstrap
        )
        #expect(route == .native(bootstrap.endpoints[0]))
    }

    @Test("Native mode never captures local resolvers")
    func nativeModePreservesLocalResolverProtection() throws {
        #expect(DNSRelayRoutingPolicy.route(
            destination: try endpoint("192.168.1.1"),
            isTrustedMClashComponent: false,
            upstreamMode: .native
        ) == .directLocalResolver)
    }

    @Test("Multicast and unspecified resolvers stay on the local network")
    func multicastAndUnspecifiedResolverAreDirect() throws {
        for address in ["224.0.0.251", "0.0.0.0", "ff02::fb", "::"] {
            #expect(DNSRelayRoutingPolicy.route(
                destination: try endpoint(address),
                isTrustedMClashComponent: false,
                upstreamMode: .native
            ) == .directLocalResolver)
        }
    }

    @Test("Native mode falls back to Mihomo for hostname-only endpoints")
    func nativeModeFallsBackForHostname() throws {
        let destination = try SOCKS5Endpoint(
            address: SOCKS5Address(domain: "resolver.example"), port: 53
        )
        #expect(DNSRelayRoutingPolicy.route(
            destination: destination,
            isTrustedMClashComponent: false,
            upstreamMode: .native
        ) == .proxy(.profileRules))
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

    @Test("DNS Profile selection ignores resolver destination rules before evaluation")
    func dnsProfileRulesAreSourceOnly() throws {
        let destinationProfile = RoutingProfileID(UUID())
        let applicationProfile = RoutingProfileID(UUID())
        let resolverRule = try CaptureRule(
            id: "resolver-ip",
            priority: 1,
            destinations: [
                .ip(try IPAddress("1.1.1.1")),
            ],
            action: .outbound(.profile(destinationProfile, target: .rules))
        )
        let applicationRule = try CaptureRule(
            id: "application",
            priority: 2,
            sources: [.userID(501)],
            action: .outbound(.profile(applicationProfile, target: .rules))
        )
        let portRule = try CaptureRule(
            id: "resolver-port",
            priority: 0,
            sources: [.userID(501)],
            portRanges: [try PortRange(lowerBound: 53, upperBound: 53)],
            action: .outbound(.profile(destinationProfile, target: .rules))
        )
        let legacyRule = try CaptureRule(
            id: "legacy",
            priority: 0,
            sources: [.userID(501)],
            action: .outbound(.profileRules)
        )

        let eligible = [resolverRule, applicationRule, portRule, legacyRule]
            .filter(DNSProfileRoutingRulePolicy.eligible)
        #expect(eligible.map(\.id) == ["application"])

        let snapshot = try CaptureConfigurationSnapshot(
            revision: 1,
            rules: eligible
        )
        let context = FlowContext(
            source: FlowSource(
                processIdentifier: 42,
                auditToken: Data(),
                userID: 501
            ),
            destination: try FlowDestination(
                ipAddress: IPAddress("1.1.1.1"),
                port: 53
            ),
            transportProtocol: .udp
        )
        let decision = CaptureRuleEngine(snapshot: snapshot).evaluate(context)
        #expect(
            decision.action
                == .outbound(.profile(applicationProfile, target: .rules))
        )
        #expect(decision.cause == .matchedRule("application"))
    }

    private func endpoint(_ address: String) throws -> SOCKS5Endpoint {
        SOCKS5Endpoint(address: SOCKS5Address(ipAddress: try IPAddress(address)), port: 53)
    }
}
