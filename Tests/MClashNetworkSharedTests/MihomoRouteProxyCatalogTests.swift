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
        let duplicateListener = try MihomoRouteProxyEndpoint(
            route: .global,
            host: "127.0.0.1",
            port: 17_001
        )
        #expect(
            throws: MihomoRouteProxyCatalogError.duplicateEndpoint(
                host: "127.0.0.1",
                port: 17_001
            )
        ) {
            try MihomoRouteProxyCatalog.validate([profile, duplicateListener])
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

    @Test("Legacy route payloads decode unchanged while explicit profile targets migrate")
    func legacyCodableCompatibilityAndMigration() throws {
        let legacyRoutes: [(MihomoRoute, String)] = [
            (.profileRules, #"{"profileRules":{}}"#),
            (.global, #"{"global":{}}"#),
            (.group("Auto"), #"{"group":{"_0":"Auto"}}"#),
        ]
        for (expected, json) in legacyRoutes {
            let decoded = try JSONDecoder().decode(
                MihomoRoute.self,
                from: Data(json.utf8)
            )
            #expect(decoded == expected)
            #expect(
                try JSONSerialization.jsonObject(with: JSONEncoder().encode(decoded))
                    as? NSDictionary
                    == JSONSerialization.jsonObject(with: Data(json.utf8))
                    as? NSDictionary
            )
        }

        let profileID = try RoutingProfileID(
            rawValue: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
        )
        let routes: [MihomoRoute] = [
            .profile(profileID, target: .rules),
            .profile(profileID, target: .global),
            .profile(profileID, target: .group("Auto")),
        ]
        for route in routes {
            #expect(
                try JSONDecoder().decode(
                    MihomoRoute.self,
                    from: JSONEncoder().encode(route)
                ) == route
            )
        }
    }

    @Test("Profile A and B route targets select only their own endpoints")
    func exactProfileEndpointSelection() throws {
        let profileA = RoutingProfileID(
            UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!
        )
        let profileB = RoutingProfileID(
            UUID(uuidString: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb")!
        )
        let routeA = MihomoRoute.profile(profileA, target: .rules)
        let routeB = MihomoRoute.profile(profileB, target: .rules)
        let endpoints = [
            try MihomoRouteProxyEndpoint(
                route: .profileRules,
                host: "127.0.0.1",
                port: 17_000
            ),
            try MihomoRouteProxyEndpoint(
                route: routeA,
                host: "127.0.0.1",
                port: 17_001
            ),
            try MihomoRouteProxyEndpoint(
                route: routeB,
                host: "127.0.0.1",
                port: 17_002
            ),
        ]

        #expect(MihomoRouteProxyCatalog.endpoint(for: routeA, in: endpoints)?.port == 17_001)
        #expect(MihomoRouteProxyCatalog.endpoint(for: routeB, in: endpoints)?.port == 17_002)
        #expect(MihomoRouteProxyCatalog.endpoint(
            for: .profile(profileA, target: .global),
            in: endpoints
        ) == nil)
    }
}
