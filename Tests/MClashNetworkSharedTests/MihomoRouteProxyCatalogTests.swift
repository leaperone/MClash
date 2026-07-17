import Foundation
import Testing
@testable import MClashNetworkShared

@Suite("Mihomo route proxy catalog")
struct MihomoRouteProxyCatalogTests {
    @Test("Catalog round-trips route-specific loopback endpoints")
    func roundTrip() throws {
        let endpoints = [
            try MihomoRouteProxyEndpoint(
                route: .profileRules,
                host: "127.0.0.1",
                port: 17_001,
                username: "extension",
                password: "secret"
            ),
            try MihomoRouteProxyEndpoint(
                route: .global,
                host: "127.0.0.1",
                port: 17_002,
                username: "extension",
                password: "secret"
            ),
            try MihomoRouteProxyEndpoint(
                route: .group("Auto"),
                host: "127.0.0.1",
                port: 17_003,
                username: "extension",
                password: "secret"
            ),
        ]

        #expect(try MihomoRouteProxyCatalog.decode(
            MihomoRouteProxyCatalog.encode(endpoints)
        ) == endpoints)
    }

    @Test("Catalog rejects missing defaults, duplicates, LAN hosts, and partial credentials")
    func validation() throws {
        let global = try MihomoRouteProxyEndpoint(
            route: .global,
            host: "127.0.0.1",
            port: 17_002
        )
        #expect(throws: MihomoRouteProxyCatalogError.missingProfileRules) {
            try MihomoRouteProxyCatalog.validate([global])
        }

        let profile = try MihomoRouteProxyEndpoint(
            route: .profileRules,
            host: "127.0.0.1",
            port: 17_001
        )
        #expect(throws: MihomoRouteProxyCatalogError.duplicateRoute(.profileRules)) {
            try MihomoRouteProxyCatalog.validate([profile, profile])
        }
        #expect(throws: MihomoRouteProxyCatalogError.nonLoopbackHost("0.0.0.0")) {
            try MihomoRouteProxyEndpoint(
                route: .profileRules,
                host: "0.0.0.0",
                port: 17_001
            )
        }
        #expect(throws: MihomoRouteProxyCatalogError.incompleteCredentials) {
            try MihomoRouteProxyEndpoint(
                route: .profileRules,
                host: "127.0.0.1",
                port: 17_001,
                username: "extension"
            )
        }
    }
}
