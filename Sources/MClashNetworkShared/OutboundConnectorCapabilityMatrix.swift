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
    /// Native outbound wire support. `support` remains the historical TCP
    /// summary for automation compatibility; these dimensions are authoritative
    /// when deciding whether a particular flow can be admitted.
    public let nativeTCP: Bool
    public let nativeUDP: Bool
    /// MClash-owned ingress support for a route. App-owned SOCKS UDP
    /// ASSOCIATE and TUN are intentionally false until their data planes exist.
    public let inboundTCP: Bool
    public let inboundUDP: Bool

    private enum CodingKeys: String, CodingKey {
        case route, protocolName, transport, support, reason
        case nativeTCP, nativeUDP, inboundTCP, inboundUDP
    }

    public init(
        route: OutboundRoute,
        protocolName: String,
        transport: String,
        support: OutboundConnectorSupportLevel,
        reason: String? = nil,
        nativeTCP: Bool? = nil,
        nativeUDP: Bool? = nil,
        inboundTCP: Bool? = nil,
        inboundUDP: Bool? = nil
    ) {
        self.route = route
        self.protocolName = protocolName
        self.transport = transport
        self.support = support
        self.reason = reason
        self.nativeTCP = nativeTCP ?? (support == .native)
        self.nativeUDP = nativeUDP ?? false
        self.inboundTCP = inboundTCP ?? (nativeTCP ?? (support == .native))
        self.inboundUDP = inboundUDP ?? false
    }

    /// New dimensions are optional on decode so diagnostics produced by older
    /// MClash versions remain readable by newer automation clients.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let support = try container.decode(OutboundConnectorSupportLevel.self, forKey: .support)
        self.init(
            route: try container.decode(OutboundRoute.self, forKey: .route),
            protocolName: try container.decode(String.self, forKey: .protocolName),
            transport: try container.decode(String.self, forKey: .transport),
            support: support,
            reason: try container.decodeIfPresent(String.self, forKey: .reason),
            nativeTCP: try container.decodeIfPresent(Bool.self, forKey: .nativeTCP)
                ?? (support == .native),
            nativeUDP: try container.decodeIfPresent(Bool.self, forKey: .nativeUDP) ?? false,
            inboundTCP: try container.decodeIfPresent(Bool.self, forKey: .inboundTCP)
                ?? (support == .native),
            inboundUDP: try container.decodeIfPresent(Bool.self, forKey: .inboundUDP) ?? false
        )
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
                    reason: result.reason,
                    nativeTCP: result.nativeTCP,
                    nativeUDP: result.nativeUDP,
                    inboundTCP: result.nativeTCP,
                    inboundUDP: false
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
    ) -> (level: OutboundConnectorSupportLevel, reason: String?, nativeTCP: Bool, nativeUDP: Bool) {
        let parameters = normalized(target.parameters)
        switch target.protocolName {
        case "http", "socks5":
            return (.native, nil, true, target.protocolName == "socks5")
        case "trojan":
            guard (parameters["network"] ?? "tcp") == "tcp" else {
                return (.legacyFallback, "Trojan transport is not implemented by the native connector.", false, false)
            }
            return (.native, nil, true, false)
        case "vless":
            let network = parameters["network"] ?? "tcp"
            guard network == "tcp" || network == "ws" else {
                return (.legacyFallback, "VLESS \(network) transport is not implemented by the native connector.", false, false)
            }
            if network == "ws",
               parameters["uuid"]?.isEmpty != false {
                return (.legacyFallback, "VLESS WebSocket requires a UUID.", false, false)
            }
            if network == "ws", target.hasInvalidVLESSWebSocketOptions {
                return (.legacyFallback, "VLESS WebSocket transport options are incomplete.", false, false)
            }
            if parameters["reality-opts"] != nil || parameters["reality-options"] != nil
                || parameters["reality"]?.isTruthy == true || parameters["xtls"]?.isTruthy == true
                || !(parameters["flow"] ?? "").isEmpty || parameters["security"] == "reality"
                || parameters["public-key"] != nil || parameters["short-id"] != nil {
                if (try? RealityConfiguration(parameters: target.parameters)) == nil {
                    return (.legacyFallback, "VLESS Reality configuration is invalid; native TLS/uTLS is unavailable.", false, false)
                }
                return (.legacyFallback, "VLESS Reality/XTLS requires a compatible custom TLS/uTLS connector.", false, false)
            }
            return (.native, nil, true, false)
        case "shadowsocks":
            if parameters["plugin"] != nil || parameters["plugin-opts"] != nil {
                return (.legacyFallback, "Shadowsocks plugins require a dedicated native transport.", false, false)
            }
            if parameters["udp-over-tcp"]?.isTruthy == true || parameters["uot"]?.isTruthy == true
                || parameters["udp-over-tcp-version"] != nil || parameters["uot-version"] != nil {
                return (.legacyFallback, "Shadowsocks UDP-over-TCP transport is not implemented by the native connector.", false, false)
            }
            let method = parameters["method"] ?? parameters["cipher"] ?? "aes-256-gcm"
            let supportedMethods = Set([
                "aes-128-gcm", "aes-256-gcm", "chacha20-ietf-poly1305"
            ])
            let password = parameters["password"] ?? parameters["passwd"] ?? ""
            guard !password.isEmpty, supportedMethods.contains(method) else {
                return (.legacyFallback, "Shadowsocks cipher or password is not supported by the native connector.", false, false)
            }
            return (.native, nil, true, false)
        case "hysteria2":
            return (.legacyFallback, "Hysteria2 requires a verified native QUIC session connector.", false, false)
        default:
            return (.unsupported, "Native connector for protocol \(protocolNameForReason(target.protocolName)) is not implemented.", false, false)
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
