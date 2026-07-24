import Foundation
import MClashNetworkShared
import Testing
@testable import MClashNetworkExtension

@Suite("Provider SOCKS destination planning")
struct ProviderSOCKSConfigurationTests {
    @Test("Mihomo receives a validated hostname while Direct retains the original IP")
    func prefersHostnameOnlyForMihomo() throws {
        let destinations = try ProviderSOCKSConfiguration.destinations(
            for: FlowRemoteEndpoint(host: "162.125.6.1", port: 443),
            preferredHostname: "chatgpt.com"
        )

        #expect(destinations.original.address.kind == .ipv4)
        #expect(destinations.original.address.ipAddress?.presentation == "162.125.6.1")
        #expect(destinations.original.address.domain == nil)
        #expect(destinations.original.port == 443)

        #expect(destinations.mihomo.address.kind == .domain)
        #expect(destinations.mihomo.address.domain == "chatgpt.com")
        #expect(destinations.mihomo.address.ipAddress == nil)
        #expect(destinations.mihomo.port == 443)
    }

    @Test("A later IP-only UDP datagram cannot inherit the initial flow hostname")
    func perDatagramPlanningDoesNotLeakInitialHostname() throws {
        let initial = try ProviderSOCKSConfiguration.destinations(
            for: FlowRemoteEndpoint(host: "162.125.6.1", port: 443),
            preferredHostname: "chatgpt.com"
        )
        let laterDatagram = try ProviderSOCKSConfiguration.destinations(
            for: FlowRemoteEndpoint(host: "203.0.113.53", port: 443),
            preferredHostname: nil
        )

        #expect(initial.mihomo.address.domain == "chatgpt.com")
        #expect(laterDatagram.original == laterDatagram.mihomo)
        #expect(laterDatagram.mihomo.address.ipAddress?.presentation == "203.0.113.53")
        #expect(laterDatagram.mihomo.address.domain == nil)
    }

    @Test("A per-datagram domain remains a domain without initial flow metadata")
    func perDatagramDomainIsPreserved() throws {
        let destinations = try ProviderSOCKSConfiguration.destinations(
            for: FlowRemoteEndpoint(host: "dns.example", port: 53),
            preferredHostname: nil
        )

        #expect(destinations.original == destinations.mihomo)
        #expect(destinations.mihomo.address.domain == "dns.example")
        #expect(destinations.mihomo.port == 53)
    }

    @Test("An invalid preferred hostname safely falls back to the original endpoint")
    func invalidPreferredHostnameFallsBackToOriginal() throws {
        let destinations = try ProviderSOCKSConfiguration.destinations(
            for: FlowRemoteEndpoint(host: "198.51.100.8", port: 443),
            preferredHostname: "invalid\u{0000}hostname"
        )

        #expect(destinations.original == destinations.mihomo)
        #expect(destinations.mihomo.address.ipAddress?.presentation == "198.51.100.8")
    }

    @Test("SOCKS domain size validation remains enforced for the preferred hostname")
    func oversizedPreferredHostnameFallsBackToOriginal() throws {
        let destinations = try ProviderSOCKSConfiguration.destinations(
            for: FlowRemoteEndpoint(host: "198.51.100.9", port: 443),
            preferredHostname: String(repeating: "a", count: 256)
        )

        #expect(destinations.original == destinations.mihomo)
        #expect(destinations.mihomo.address.ipAddress?.presentation == "198.51.100.9")
    }

    @Test("Profile A and B decode to distinct provider endpoints")
    func profileCatalogSelectsExactEndpoint() throws {
        let (routeA, routeB, data) = try profileCatalog()
        let catalog = try #require(ProviderSOCKSConfiguration.routeCatalog(
            providerConfiguration: [
                ProviderConfigurationKey.mihomoRouteProxyCatalog: data
            ]
        ))

        #expect(ProviderSOCKSConfiguration.proxy(for: routeA, in: catalog)?.port == 18_001)
        #expect(ProviderSOCKSConfiguration.proxy(for: routeB, in: catalog)?.port == 18_002)
        #expect(ProviderSOCKSConfiguration.proxy(
            for: .profileRules,
            in: catalog
        )?.port == 18_000)
    }

    @Test("TCP plan uses the requested profile endpoint and does not alias a missing target")
    func tcpProfilePlan() throws {
        let (routeA, routeB, data) = try profileCatalog()
        let catalog = try #require(ProviderSOCKSConfiguration.routeCatalog(
            providerConfiguration: [
                ProviderConfigurationKey.mihomoRouteProxyCatalog: data
            ]
        ))
        let endpoint = FlowRemoteEndpoint(host: "203.0.113.10", port: 443)

        let profileAPlan = try #require(try ProviderSOCKSConfiguration.flowPlan(
            for: decision(routeA),
            endpoint: endpoint,
            preferredHostname: "api.example.com",
            routeCatalog: catalog
        ))
        let missingPlan = try #require(try ProviderSOCKSConfiguration.flowPlan(
            for: decision(.profile(
                routeA.routingProfileID!,
                target: .global
            )),
            endpoint: endpoint,
            preferredHostname: "api.example.com",
            routeCatalog: catalog
        ))

        #expect(profileAPlan.proxy?.port == 18_001)
        #expect(profileAPlan.destinations.mihomo.address.domain == "api.example.com")
        #expect(missingPlan.proxy == nil)
        #expect(ProviderSOCKSConfiguration.proxy(for: routeB, in: catalog)?.port == 18_002)
    }

    @Test("UDP plan independently selects Profile B for each datagram target")
    func udpProfilePlan() throws {
        let (_, routeB, data) = try profileCatalog()
        let catalog = try #require(ProviderSOCKSConfiguration.routeCatalog(
            providerConfiguration: [
                ProviderConfigurationKey.mihomoRouteProxyCatalog: data
            ]
        ))

        let plan = try #require(try ProviderSOCKSConfiguration.flowPlan(
            for: decision(routeB),
            endpoint: FlowRemoteEndpoint(host: "198.51.100.53", port: 53),
            preferredHostname: nil,
            routeCatalog: catalog
        ))

        #expect(plan.proxy?.port == 18_002)
        #expect(plan.destinations.original == plan.destinations.mihomo)
        #expect(plan.destinations.mihomo.port == 53)
    }

    private func decision(_ route: MihomoRoute) -> FlowTrafficDecision {
        FlowTrafficDecision(
            disposition: .mihomo(route),
            reason: .rule(.matchedRule("test"))
        )
    }

    private func profileCatalog() throws -> (
        routeA: MihomoRoute,
        routeB: MihomoRoute,
        data: Data
    ) {
        let profileA = RoutingProfileID(
            UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!
        )
        let profileB = RoutingProfileID(
            UUID(uuidString: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb")!
        )
        let routeA = MihomoRoute.profile(profileA, target: .rules)
        let routeB = MihomoRoute.profile(profileB, target: .rules)
        return (
            routeA,
            routeB,
            try MihomoRouteProxyCatalog.encode([
                try MihomoRouteProxyEndpoint(
                    route: .profileRules,
                    host: "127.0.0.1",
                    port: 18_000
                ),
                try MihomoRouteProxyEndpoint(
                    route: routeA,
                    host: "127.0.0.1",
                    port: 18_001
                ),
                try MihomoRouteProxyEndpoint(
                    route: routeB,
                    host: "127.0.0.1",
                    port: 18_002
                ),
            ])
        )
    }
}
