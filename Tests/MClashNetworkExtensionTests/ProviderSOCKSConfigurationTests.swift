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
}
