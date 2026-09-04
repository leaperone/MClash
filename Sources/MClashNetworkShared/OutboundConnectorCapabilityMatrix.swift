import Foundation

/// The implementation available for one imported outbound target.
///
/// This is deliberately defined in the shared model layer so the app, CLI,
/// and Network Extension can describe the same connector contract without
/// exposing Mihomo's controller or YAML vocabulary.
public enum OutboundConnectorSupportLevel: String, Codable, Equatable, Sendable {
    case native
    case legacyFallback
    case unsupported
}

public struct OutboundConnectorCapabilityMatrixEntry: Codable, Equatable, Sendable {
    public let route: OutboundRoute
    public let protocolName: String
    public let transport: String
    public let support: OutboundConnectorSupportLevel
    public let reason: String?

    public init(
        route: OutboundRoute,
        protocolName: String,
        transport: String,
        support: OutboundConnectorSupportLevel,
        reason: String? = nil
    ) {
        self.route = route
        self.protocolName = protocolName
        self.transport = transport
        self.support = support
        self.reason = reason
    }
}

/// Produces a stable, connector-neutral report for every entry in a node
/// catalog. It is descriptive only: generating a matrix never changes route
/// selection or activates a backend.
public enum OutboundConnectorCapabilityMatrix {
    /// Shared admission signal used by group selection. Native runtimes should
    /// prefer a usable native target over a faster compatibility-only target,
    /// while still retaining the latter when a group has no native member so
    /// diagnostics can explain the unsupported route.
    public static func support(
        for target: OutboundNodeTarget
    ) -> OutboundConnectorSupportLevel {
        classify(target).level
    }

    public static func entries(
        for catalog: OutboundNodeTargetCatalog
    ) -> [OutboundConnectorCapabilityMatrixEntry] {
        catalog.entries
            .sorted { $0.route.stableSortKey < $1.route.stableSortKey }
            .map { entry in
                let target = entry.target
                let protocolName = target.protocolName
                let transport = transportName(for: target)
                let result = classify(target)
                return OutboundConnectorCapabilityMatrixEntry(
                    route: entry.route,
                    protocolName: protocolName,
                    transport: transport,
                    support: result.level,
                    reason: result.reason
                )
            }
    }

    private static func transportName(for target: OutboundNodeTarget) -> String {
        let parameters = normalized(target.parameters)
        if let network = parameters["network"], !network.isEmpty {
            return network
        }
        switch target.protocolName {
        case "hysteria2": return "quic"
        case "http", "socks5", "shadowsocks", "trojan", "vless": return "tcp"
        default: return "unknown"
        }
    }

    private static func classify(
        _ target: OutboundNodeTarget
    ) -> (level: OutboundConnectorSupportLevel, reason: String?) {
        let parameters = normalized(target.parameters)
        switch target.protocolName {
        case "http", "socks5":
            return (.native, nil)
        case "trojan":
            guard (parameters["network"] ?? "tcp") == "tcp" else {
                return (.legacyFallback, "Trojan transport is not implemented by the native connector.")
            }
            return (.native, nil)
        case "vless":
            let network = parameters["network"] ?? "tcp"
            guard network == "tcp" || network == "ws" else {
                return (.legacyFallback, "VLESS \(network) transport is not implemented by the native connector.")
            }
            if network == "ws",
               parameters["uuid"]?.isEmpty != false {
                return (.legacyFallback, "VLESS WebSocket requires a UUID.")
            }
            if parameters["reality-opts"] != nil || parameters["reality-options"] != nil
                || parameters["reality"]?.isTruthy == true || parameters["xtls"]?.isTruthy == true
                || !(parameters["flow"] ?? "").isEmpty || parameters["security"] == "reality"
                || parameters["public-key"] != nil || parameters["short-id"] != nil {
                if (try? RealityConfiguration(parameters: target.parameters)) == nil {
                    return (.legacyFallback, "VLESS Reality configuration is invalid; native TLS/uTLS is unavailable.")
                }
                return (.legacyFallback, "VLESS Reality/XTLS requires a compatible custom TLS/uTLS connector.")
            }
            return (.native, nil)
        case "shadowsocks":
            if parameters["plugin"] != nil || parameters["plugin-opts"] != nil {
                return (.legacyFallback, "Shadowsocks plugins require a dedicated native transport.")
            }
            if parameters["udp-over-tcp"]?.isTruthy == true || parameters["uot"]?.isTruthy == true
                || parameters["udp-over-tcp-version"] != nil || parameters["uot-version"] != nil {
                return (.legacyFallback, "Shadowsocks UDP-over-TCP transport is not implemented by the native connector.")
            }
            let method = parameters["method"] ?? parameters["cipher"] ?? "aes-256-gcm"
            let supportedMethods = Set([
                "aes-128-gcm", "aes-256-gcm", "chacha20-ietf-poly1305"
            ])
            let password = parameters["password"] ?? parameters["passwd"] ?? ""
            guard !password.isEmpty, supportedMethods.contains(method) else {
                return (.legacyFallback, "Shadowsocks cipher or password is not supported by the native connector.")
            }
            return (.native, nil)
        case "hysteria2":
            return (.legacyFallback, "Hysteria2 requires a verified native QUIC session connector.")
        default:
            return (.unsupported, "Native connector for protocol \(protocolNameForReason(target.protocolName)) is not implemented.")
        }
    }

    private static func normalized(_ values: [String: String]) -> [String: String] {
        Dictionary(values.map { key, value in
            (key.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().replacingOccurrences(of: "_", with: "-"), value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
        }, uniquingKeysWith: { first, _ in first })
    }

    private static func protocolNameForReason(_ value: String) -> String {
        String(value.prefix(32))
    }
}

private extension String {
    var isTruthy: Bool { ["true", "yes", "1", "on"].contains(self) }
}
