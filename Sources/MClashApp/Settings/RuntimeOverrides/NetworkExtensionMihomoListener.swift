import CryptoKit
import Foundation
import MClashNetworkShared

/// The real profile's public Mixed entry point when that same profile is also
/// backing the virtual Default Profile in the primary core.
///
/// Auxiliary profiles use their root `mixed-port`. The primary core uses its
/// root `mixed-port` for the stable virtual Default Profile and this managed
/// loopback listener for the real profile's own identity.
public struct ManagedProfileMixedListenerConfiguration: Equatable, Sendable {
    public static let host = "127.0.0.1"
    public static let listenerName = "mclash-profile-mixed"

    public let port: UInt16

    public init(port: Int) throws {
        guard (1...Int(UInt16.max)).contains(port) else {
            throw NetworkExtensionMihomoListenerValidationError.invalidPort(port)
        }
        self.port = UInt16(port)
    }
}

/// Credentials used only by the private SOCKS5 listener that connects the
/// Network Extension data plane to mihomo.
///
/// This value deliberately is not `Codable`: it is runtime session material,
/// not part of the user-owned runtime override document. Callers that need a
/// durable secret should keep it in Keychain and reconstruct this value when
/// composing the active mihomo configuration.
public struct NetworkExtensionMihomoAuthentication: Equatable, Sendable {
    public let username: String
    public let password: String

    public init(username: String, password: String) throws {
        try Self.validate(username, field: .username)
        try Self.validate(password, field: .password)
        self.username = username
        self.password = password
    }

    private static func validate(
        _ value: String,
        field: NetworkExtensionMihomoListenerValidationError.CredentialField
    ) throws {
        let byteCount = value.lengthOfBytes(using: .utf8)
        guard (1 ... 255).contains(byteCount) else {
            throw NetworkExtensionMihomoListenerValidationError.invalidCredentialLength(
                field: field,
                utf8ByteCount: byteCount
            )
        }
        guard !value.contains(where: { $0 == "\0" || $0 == "\n" || $0 == "\r" }) else {
            throw NetworkExtensionMihomoListenerValidationError.invalidCredentialCharacters(
                field: field
            )
        }
    }
}

/// The application-owned SOCKS5 entry point consumed by the Network
/// Extension. The listen addresses are constants rather than caller input so
/// this layer can never expose the listener on a LAN or wildcard interface.
///
/// Two mihomo listeners are emitted on the same port: one bound to IPv4
/// loopback and one bound to IPv6 loopback. Both explicitly enable UDP for
/// SOCKS5 UDP ASSOCIATE. When `authentication` is nil the composer writes an
/// empty `users` array so a profile's global authentication cannot
/// accidentally become an implicit dependency of the extension.
public struct NetworkExtensionMihomoListenerConfiguration: Equatable, Sendable {
    public static let ipv4Host = "127.0.0.1"
    public static let ipv6Host = "::1"
    public static let ipv4ListenerName = "mclash-network-extension-socks-ipv4"
    public static let ipv6ListenerName = "mclash-network-extension-socks-ipv6"
    public static let listenerNamePrefix = "mclash-network-extension-socks"

    public struct RouteListener: Equatable, Sendable {
        public let route: MihomoRoute
        public let port: UInt16

        fileprivate var outboundProxy: String? {
            switch route.profileRoute {
            case .rules: nil
            case .global: "GLOBAL"
            case let .group(group): group
            }
        }
    }

    struct ListenerDescriptor: Equatable, Sendable {
        let route: MihomoRoute
        let name: String
        let host: String
        let port: UInt16
        let outboundProxy: String?
    }

    public let port: UInt16
    public let authentication: NetworkExtensionMihomoAuthentication?
    public let routeListeners: [RouteListener]
    public let includesLegacyProfileRules: Bool

    public init(
        port: Int,
        authentication: NetworkExtensionMihomoAuthentication? = nil,
        routePorts: [MihomoRoute: Int] = [:],
        includesLegacyProfileRules: Bool = true
    ) throws {
        guard (1 ... Int(UInt16.max)).contains(port) else {
            throw NetworkExtensionMihomoListenerValidationError.invalidPort(port)
        }
        self.port = UInt16(port)
        self.authentication = authentication
        self.includesLegacyProfileRules = includesLegacyProfileRules

        var requested = routePorts
        if includesLegacyProfileRules {
            requested[.profileRules] = port
        }
        guard !requested.isEmpty else {
            throw NetworkExtensionMihomoListenerValidationError.missingRoute
        }
        let sorted = requested.sorted {
            Self.routeSortKey($0.key) < Self.routeSortKey($1.key)
        }
        var usedPorts = Set<UInt16>()
        routeListeners = try sorted.map { route, value in
            guard (1 ... Int(UInt16.max)).contains(value) else {
                throw NetworkExtensionMihomoListenerValidationError.invalidPort(value)
            }
            let routePort = UInt16(value)
            guard usedPorts.insert(routePort).inserted else {
                throw NetworkExtensionMihomoListenerValidationError.duplicatePort(value)
            }
            return RouteListener(route: route, port: routePort)
        }
    }

    public var ipv4Endpoint: NetworkExtensionMihomoEndpoint {
        NetworkExtensionMihomoEndpoint(host: Self.ipv4Host, port: port)
    }

    public var ipv6Endpoint: NetworkExtensionMihomoEndpoint {
        NetworkExtensionMihomoEndpoint(host: Self.ipv6Host, port: port)
    }

    public func endpoint(for route: MihomoRoute) -> NetworkExtensionMihomoEndpoint? {
        routeListeners.first(where: { $0.route == route }).map {
            NetworkExtensionMihomoEndpoint(host: Self.ipv4Host, port: $0.port)
        }
    }

    /// Returns a listener configuration containing only the requested routes,
    /// while preserving the authenticated listener and every retained route's
    /// port.  The live updater normally keeps removed routes as an endpoint
    /// superset so existing relays can drain; callers may use this narrow
    /// operation when a policy target was renamed or deleted and the old
    /// outbound proxy name would otherwise remain executable in Mihomo.
    public func retaining(routes requested: Set<MihomoRoute>) throws -> Self {
        let routePorts = Dictionary(
            uniqueKeysWithValues: routeListeners
                .filter { requested.contains($0.route) }
                .map { ($0.route, Int($0.port)) }
        )
        return try Self(
            port: Int(port),
            authentication: authentication,
            routePorts: routePorts,
            includesLegacyProfileRules: includesLegacyProfileRules
        )
    }

    public func encodedRouteProxyCatalog() throws -> Data {
        try MihomoRouteProxyCatalog.encode(try routeProxyEndpoints())
    }

    public func routeProxyEndpoints() throws -> [MihomoRouteProxyEndpoint] {
        try routeListeners.map { listener in
            try MihomoRouteProxyEndpoint(
                route: listener.route,
                host: Self.ipv4Host,
                port: listener.port,
                username: authentication?.username,
                password: authentication?.password
            )
        }
    }

    var listenerDescriptors: [ListenerDescriptor] {
        routeListeners.flatMap { listener in
            let names: [(String, String)]
            if listener.route == .profileRules {
                names = [(Self.ipv4ListenerName, Self.ipv4Host),
                         (Self.ipv6ListenerName, Self.ipv6Host)]
            } else {
                let suffix = Self.routeIdentitySuffix(listener.route)
                names = [
                    ("\(Self.listenerNamePrefix)-route-\(suffix)-ipv4", Self.ipv4Host),
                    ("\(Self.listenerNamePrefix)-route-\(suffix)-ipv6", Self.ipv6Host),
                ]
            }
            return names.map { name, host in
                ListenerDescriptor(
                    route: listener.route,
                    name: name,
                    host: host,
                    port: listener.port,
                    outboundProxy: listener.outboundProxy
                )
            }
        }
    }

    private static func routeSortKey(_ route: MihomoRoute) -> String {
        route.stableSortKey
    }

    private static func routeIdentitySuffix(_ route: MihomoRoute) -> String {
        SHA256.hash(data: Data(route.stableSortKey.utf8))
            .prefix(8)
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

public struct NetworkExtensionMihomoEndpoint: Equatable, Sendable {
    public let host: String
    public let port: UInt16

    public init(host: String, port: UInt16) {
        self.host = host
        self.port = port
    }
}

public enum NetworkExtensionMihomoListenerValidationError: Error, Equatable, Sendable {
    public enum CredentialField: String, Equatable, Sendable {
        case username
        case password
    }

    case invalidPort(Int)
    case duplicatePort(Int)
    case missingRoute
    case invalidCredentialLength(field: CredentialField, utf8ByteCount: Int)
    case invalidCredentialCharacters(field: CredentialField)
}

extension NetworkExtensionMihomoListenerValidationError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case let .invalidPort(port):
            AppLocalization.format(
                "The Network Extension SOCKS5 port must be between 1 and 65535; received %d.",
                port
            )
        case let .duplicatePort(port):
            AppLocalization.format(
                "Each private App Routing route needs a distinct SOCKS5 port; %d was reused.",
                port
            )
        case .missingRoute:
            AppLocalization.string(
                "A private App Routing listener configuration needs at least one route."
            )
        case let .invalidCredentialLength(field, byteCount):
            AppLocalization.format(
                "The Network Extension SOCKS5 %@ must contain 1 to 255 UTF-8 bytes; received %d.",
                field.rawValue,
                byteCount
            )
        case let .invalidCredentialCharacters(field):
            AppLocalization.format(
                "The Network Extension SOCKS5 %@ cannot contain null bytes or line breaks.",
                field.rawValue
            )
        }
    }
}
