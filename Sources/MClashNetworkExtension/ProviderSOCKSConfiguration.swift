import Foundation
import MClashNetworkShared
@preconcurrency import Network

struct ProviderSOCKSConfiguration: Equatable, Sendable {
    let host: String
    let port: UInt16
    let credentials: SOCKS5UsernamePasswordCredentials?

    init?(providerConfiguration: [String: Any]?) {
        guard let providerConfiguration,
              let host = providerConfiguration[ProviderConfigurationKey.mihomoSOCKSHost]
                as? String,
              host == "127.0.0.1" || host == "::1",
              let port = Self.uint16(
                providerConfiguration[ProviderConfigurationKey.mihomoSOCKSPort]
              )
        else {
            return nil
        }

        let username = providerConfiguration[
            ProviderConfigurationKey.mihomoSOCKSUsername
        ] as? String
        let password = providerConfiguration[
            ProviderConfigurationKey.mihomoSOCKSPassword
        ] as? String
        let credentials: SOCKS5UsernamePasswordCredentials?
        switch (username, password) {
        case (nil, nil):
            credentials = nil
        case let (username?, password?):
            guard let value = try? SOCKS5UsernamePasswordCredentials(
                username: username,
                password: password
            ) else {
                return nil
            }
            credentials = value
        default:
            return nil
        }

        self.host = host
        self.port = port
        self.credentials = credentials
    }

    init?(routeEndpoint: MihomoRouteProxyEndpoint) {
        guard routeEndpoint.host == "127.0.0.1" || routeEndpoint.host == "::1",
              routeEndpoint.port > 0
        else { return nil }
        let credentials: SOCKS5UsernamePasswordCredentials?
        switch (routeEndpoint.username, routeEndpoint.password) {
        case (nil, nil):
            credentials = nil
        case let (username?, password?):
            guard let value = try? SOCKS5UsernamePasswordCredentials(
                username: username,
                password: password
            ) else { return nil }
            credentials = value
        default:
            return nil
        }
        host = routeEndpoint.host
        port = routeEndpoint.port
        self.credentials = credentials
    }

    static func routeCatalog(
        providerConfiguration: [String: Any]?
    ) -> [MihomoRoute: ProviderSOCKSConfiguration]? {
        guard let providerConfiguration else { return nil }
        if let data = providerConfiguration[
            ProviderConfigurationKey.mihomoRouteProxyCatalog
        ] as? Data {
            guard let endpoints = try? MihomoRouteProxyCatalog.decode(data) else {
                return nil
            }
            var result: [MihomoRoute: ProviderSOCKSConfiguration] = [:]
            for endpoint in endpoints {
                guard let configuration = ProviderSOCKSConfiguration(
                    routeEndpoint: endpoint
                ) else { return nil }
                result[endpoint.route] = configuration
            }
            return result[.profileRules] == nil ? nil : result
        }
        guard let profileRules = ProviderSOCKSConfiguration(
            providerConfiguration: providerConfiguration
        ) else { return nil }
        return [.profileRules: profileRules]
    }

    var networkHost: NWEndpoint.Host { NWEndpoint.Host(host) }

    var networkPort: NWEndpoint.Port {
        // `port` is already non-zero and UInt16-bounded by construction.
        NWEndpoint.Port(rawValue: port)!
    }

    func destination(for endpoint: FlowRemoteEndpoint) throws -> SOCKS5Endpoint {
        try Self.destination(for: endpoint)
    }

    static func destination(for endpoint: FlowRemoteEndpoint) throws -> SOCKS5Endpoint {
        var host = endpoint.host.trimmingCharacters(in: .whitespacesAndNewlines)
        if host.hasPrefix("["), host.hasSuffix("]") {
            host.removeFirst()
            host.removeLast()
        }
        guard let port = UInt16(endpoint.port), port > 0 else {
            throw FlowContextConversionFailure.invalidRemotePort(endpoint.port)
        }
        if let address = try? IPAddress(host) {
            return SOCKS5Endpoint(address: SOCKS5Address(ipAddress: address), port: port)
        }
        return SOCKS5Endpoint(address: try SOCKS5Address(domain: host), port: port)
    }

    private static func uint16(_ value: Any?) -> UInt16? {
        switch value {
        case let value as UInt16 where value > 0:
            value
        case let value as Int where (1 ... Int(UInt16.max)).contains(value):
            UInt16(value)
        case let value as NSNumber where (1 ... Int(UInt16.max)).contains(value.intValue):
            UInt16(value.intValue)
        case let value as String:
            UInt16(value).flatMap { $0 > 0 ? $0 : nil }
        default:
            nil
        }
    }
}
