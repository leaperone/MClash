import Testing
@testable import MClashNetworkShared

@Suite("Outbound node target catalog")
struct OutboundNodeTargetCatalogTests {
    @Test("Round-trips route to node target mappings")
    func roundTrips() throws {
        let target = try OutboundNodeTarget(protocolName: "socks5", host: "127.0.0.1", port: 1080)
        let catalog = try OutboundNodeTargetCatalog(entries: [
            .init(route: .group("AI"), target: target)
        ])
        let decoded = try OutboundNodeTargetCatalog.decode(catalog.encoded())
        #expect(decoded == catalog)
        #expect(decoded.target(for: .group("AI")) == target)
    }

    @Test("Rejects duplicate route entries")
    func rejectsDuplicates() throws {
        let first = try OutboundNodeTarget(protocolName: "socks5", host: "127.0.0.1", port: 1080)
        let second = try OutboundNodeTarget(protocolName: "socks5", host: "127.0.0.1", port: 1081)
        #expect(throws: OutboundNodeTargetCatalogError.duplicateRoute) {
            try OutboundNodeTargetCatalog(entries: [
                .init(route: .global, target: first),
                .init(route: .global, target: second),
            ])
        }
    }
}
