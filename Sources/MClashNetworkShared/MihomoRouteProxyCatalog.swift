import Foundation

/// One private loopback SOCKS5 endpoint dedicated to a requested Mihomo
/// routing target. It is carried only in Network Extension configuration; it
/// is never written to traffic history or provider status files.
public struct MihomoRouteProxyEndpoint: Codable, Equatable, Sendable {
    public let route: MihomoRoute
    public let host: String
    public let port: UInt16
    public let username: String?
    public let password: String?

    public init(
        route: MihomoRoute,
        host: String,
        port: UInt16,
        username: String? = nil,
        password: String? = nil
    ) throws {
        guard host == "127.0.0.1" || host == "::1" else {
            throw MihomoRouteProxyCatalogError.nonLoopbackHost(host)
        }
        guard port > 0 else {
            throw MihomoRouteProxyCatalogError.invalidPort(port)
        }
        guard (username == nil) == (password == nil) else {
            throw MihomoRouteProxyCatalogError.incompleteCredentials
        }
        self.route = route
        self.host = host
        self.port = port
        self.username = username
        self.password = password
    }
}

public enum MihomoRouteProxyCatalogError: Error, Equatable, Sendable {
    case nonLoopbackHost(String)
    case invalidPort(UInt16)
    case incompleteCredentials
    case duplicateRoute(MihomoRoute)
    case missingProfileRules
    case encodedCatalogTooLarge(actual: Int, maximum: Int)
}

extension MihomoRouteProxyCatalogError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case let .nonLoopbackHost(host):
            "A private App Routing listener must use loopback; received \(host)."
        case let .invalidPort(port):
            "A private App Routing listener has invalid port \(port)."
        case .incompleteCredentials:
            "A private App Routing listener must provide both username and password or neither."
        case let .duplicateRoute(route):
            "The private App Routing listener catalog contains duplicate route \(route)."
        case .missingProfileRules:
            "The private App Routing listener catalog is missing the profile-rules route."
        case let .encodedCatalogTooLarge(actual, maximum):
            "The encoded private App Routing listener catalog is \(actual) bytes; the maximum is \(maximum)."
        }
    }
}

public enum MihomoRouteProxyCatalog {
    public static let maximumEncodedSize = 64 * 1_024

    public static func validate(_ endpoints: [MihomoRouteProxyEndpoint]) throws {
        var routes = Set<MihomoRoute>()
        for endpoint in endpoints {
            _ = try MihomoRouteProxyEndpoint(
                route: endpoint.route,
                host: endpoint.host,
                port: endpoint.port,
                username: endpoint.username,
                password: endpoint.password
            )
            guard routes.insert(endpoint.route).inserted else {
                throw MihomoRouteProxyCatalogError.duplicateRoute(endpoint.route)
            }
        }
        guard routes.contains(.profileRules) else {
            throw MihomoRouteProxyCatalogError.missingProfileRules
        }
    }

    public static func encode(_ endpoints: [MihomoRouteProxyEndpoint]) throws -> Data {
        try validate(endpoints)
        let data = try JSONEncoder().encode(endpoints)
        guard data.count <= maximumEncodedSize else {
            throw MihomoRouteProxyCatalogError.encodedCatalogTooLarge(
                actual: data.count,
                maximum: maximumEncodedSize
            )
        }
        return data
    }

    public static func decode(_ data: Data) throws -> [MihomoRouteProxyEndpoint] {
        guard data.count <= maximumEncodedSize else {
            throw MihomoRouteProxyCatalogError.encodedCatalogTooLarge(
                actual: data.count,
                maximum: maximumEncodedSize
            )
        }
        let endpoints = try JSONDecoder().decode(
            [MihomoRouteProxyEndpoint].self,
            from: data
        )
        try validate(endpoints)
        return endpoints
    }
}
