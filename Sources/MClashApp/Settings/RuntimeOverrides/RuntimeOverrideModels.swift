import Foundation

/// Persistent, user-owned values that are layered over an immutable profile
/// when MClash prepares the configuration passed to mihomo.
///
/// `nil` means "inherit the profile value". A concrete value, including zero
/// or an empty string, is an explicit override.
public struct RuntimeOverrides: Codable, Equatable, Sendable {
    public var ports: RuntimePortOverrides
    public var allowLAN: Bool?
    public var bindAddress: String?
    public var ipv6: Bool?
    public var sniffing: Bool?
    public var tcpConcurrent: Bool?
    public var findProcessMode: String?
    public var interfaceName: String?
    public var logLevel: String?
    /// `nil` inherits the profile's complete `dns` section. A non-nil value
    /// is an authoritative replacement for that section.
    public var dns: RuntimeDNSOverrides?
    /// Rules inserted before the immutable profile's top-level `rules`
    /// sequence. `nil` means no prepend layer is configured. An empty array is
    /// persisted as an explicit, currently empty layer and contributes no
    /// generated rules.
    public var prependRules: [String]?
    /// Rules inserted after the immutable profile's top-level `rules`
    /// sequence. `nil` means no append layer is configured. An empty array is
    /// persisted as an explicit, currently empty layer and contributes no
    /// generated rules.
    public var appendRules: [String]?

    // TUN intentionally remains outside the composer for now. It can be
    // added as another optional Codable section without changing v1 keys;
    // schema migrations are centralized in RuntimeOverrideStore if its
    // eventual representation needs a bump.

    public init(
        ports: RuntimePortOverrides = RuntimePortOverrides(),
        allowLAN: Bool? = nil,
        bindAddress: String? = nil,
        ipv6: Bool? = nil,
        sniffing: Bool? = nil,
        tcpConcurrent: Bool? = nil,
        findProcessMode: String? = nil,
        interfaceName: String? = nil,
        logLevel: String? = nil,
        dns: RuntimeDNSOverrides? = nil,
        prependRules: [String]? = nil,
        appendRules: [String]? = nil
    ) {
        self.ports = ports
        self.allowLAN = allowLAN
        self.bindAddress = bindAddress
        self.ipv6 = ipv6
        self.sniffing = sniffing
        self.tcpConcurrent = tcpConcurrent
        self.findProcessMode = findProcessMode
        self.interfaceName = interfaceName
        self.logLevel = logLevel
        self.dns = dns
        self.prependRules = prependRules
        self.appendRules = appendRules
    }

    public static let empty = RuntimeOverrides()

    public var isEmpty: Bool {
        ports.isEmpty
            && allowLAN == nil
            && bindAddress == nil
            && ipv6 == nil
            && sniffing == nil
            && tcpConcurrent == nil
            && findProcessMode == nil
            && interfaceName == nil
            && logLevel == nil
            && dns == nil
            && (prependRules?.isEmpty ?? true)
            && (appendRules?.isEmpty ?? true)
    }

    private enum CodingKeys: String, CodingKey {
        case ports
        case allowLAN
        case bindAddress
        case ipv6
        case sniffing
        case tcpConcurrent
        case findProcessMode
        case interfaceName
        case logLevel
        case dns
        case prependRules
        case appendRules
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        ports = try container.decodeIfPresent(RuntimePortOverrides.self, forKey: .ports) ?? .init()
        allowLAN = try container.decodeIfPresent(Bool.self, forKey: .allowLAN)
        bindAddress = try container.decodeIfPresent(String.self, forKey: .bindAddress)
        ipv6 = try container.decodeIfPresent(Bool.self, forKey: .ipv6)
        sniffing = try container.decodeIfPresent(Bool.self, forKey: .sniffing)
        tcpConcurrent = try container.decodeIfPresent(Bool.self, forKey: .tcpConcurrent)
        findProcessMode = try container.decodeIfPresent(String.self, forKey: .findProcessMode)
        interfaceName = try container.decodeIfPresent(String.self, forKey: .interfaceName)
        logLevel = try container.decodeIfPresent(String.self, forKey: .logLevel)
        dns = try container.decodeIfPresent(RuntimeDNSOverrides.self, forKey: .dns)
        prependRules = try container.decodeIfPresent([String].self, forKey: .prependRules)
        appendRules = try container.decodeIfPresent([String].self, forKey: .appendRules)
    }
}

public enum RuntimeDNSEnhancedMode: String, Codable, CaseIterable, Sendable {
    case fakeIP = "fake-ip"
    case redirHost = "redir-host"
}

/// An authoritative mihomo `dns` section.
///
/// The section itself is optional on `RuntimeOverrides`: a nil section
/// inherits the profile bytes unchanged. Once present, only concrete fields
/// below are emitted; nil fields use mihomo defaults rather than being merged
/// from the profile. This keeps activation deterministic for block and flow
/// style YAML without rewriting the source profile.
public struct RuntimeDNSOverrides: Codable, Equatable, Sendable {
    public var enable: Bool?
    public var listen: String?
    public var ipv6: Bool?
    public var enhancedMode: RuntimeDNSEnhancedMode?
    public var fakeIPRange: String?
    public var fakeIPFilter: [String]?
    public var defaultNameserver: [String]?
    public var nameserver: [String]?
    public var fallback: [String]?
    public var proxyServerNameserver: [String]?
    public var directNameserver: [String]?
    public var respectRules: Bool?
    public var useHosts: Bool?
    public var useSystemHosts: Bool?
    public var preferH3: Bool?

    public init(
        enable: Bool? = nil,
        listen: String? = nil,
        ipv6: Bool? = nil,
        enhancedMode: RuntimeDNSEnhancedMode? = nil,
        fakeIPRange: String? = nil,
        fakeIPFilter: [String]? = nil,
        defaultNameserver: [String]? = nil,
        nameserver: [String]? = nil,
        fallback: [String]? = nil,
        proxyServerNameserver: [String]? = nil,
        directNameserver: [String]? = nil,
        respectRules: Bool? = nil,
        useHosts: Bool? = nil,
        useSystemHosts: Bool? = nil,
        preferH3: Bool? = nil
    ) {
        self.enable = enable
        self.listen = listen
        self.ipv6 = ipv6
        self.enhancedMode = enhancedMode
        self.fakeIPRange = fakeIPRange
        self.fakeIPFilter = fakeIPFilter
        self.defaultNameserver = defaultNameserver
        self.nameserver = nameserver
        self.fallback = fallback
        self.proxyServerNameserver = proxyServerNameserver
        self.directNameserver = directNameserver
        self.respectRules = respectRules
        self.useHosts = useHosts
        self.useSystemHosts = useSystemHosts
        self.preferH3 = preferH3
    }
}

public struct RuntimePortOverrides: Codable, Equatable, Sendable {
    public var port: Int?
    public var socksPort: Int?
    public var redirPort: Int?
    public var tproxyPort: Int?
    public var mixedPort: Int?

    public init(
        port: Int? = nil,
        socksPort: Int? = nil,
        redirPort: Int? = nil,
        tproxyPort: Int? = nil,
        mixedPort: Int? = nil
    ) {
        self.port = port
        self.socksPort = socksPort
        self.redirPort = redirPort
        self.tproxyPort = tproxyPort
        self.mixedPort = mixedPort
    }

    public var isEmpty: Bool {
        port == nil
            && socksPort == nil
            && redirPort == nil
            && tproxyPort == nil
            && mixedPort == nil
    }
}

public enum RuntimeOverrideValidationError: Error, Equatable, Sendable {
    case invalidPort(field: String, value: Int)
    case invalidScalar(field: String)
}

extension RuntimeOverrideValidationError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case let .invalidPort(field, value):
            "The \(field) override must be between 0 and 65535; received \(value)."
        case let .invalidScalar(field):
            "The \(field) override contains a line break or null byte."
        }
    }
}

public struct RuntimeOverrideValidator: Sendable {
    public init() {}

    public func validate(_ overrides: RuntimeOverrides) throws {
        let ports: [(String, Int?)] = [
            ("port", overrides.ports.port),
            ("socks-port", overrides.ports.socksPort),
            ("redir-port", overrides.ports.redirPort),
            ("tproxy-port", overrides.ports.tproxyPort),
            ("mixed-port", overrides.ports.mixedPort),
        ]
        for (field, value) in ports {
            if let value, !(0...65_535).contains(value) {
                throw RuntimeOverrideValidationError.invalidPort(field: field, value: value)
            }
        }

        let scalars: [(String, String?)] = [
            ("bind-address", overrides.bindAddress),
            ("find-process-mode", overrides.findProcessMode),
            ("interface-name", overrides.interfaceName),
            ("log-level", overrides.logLevel),
            ("dns.listen", overrides.dns?.listen),
            ("dns.fake-ip-range", overrides.dns?.fakeIPRange),
        ]
        let lists: [(String, [String]?)] = [
            ("dns.fake-ip-filter", overrides.dns?.fakeIPFilter),
            ("dns.default-nameserver", overrides.dns?.defaultNameserver),
            ("dns.nameserver", overrides.dns?.nameserver),
            ("dns.fallback", overrides.dns?.fallback),
            ("dns.proxy-server-nameserver", overrides.dns?.proxyServerNameserver),
            ("dns.direct-nameserver", overrides.dns?.directNameserver),
            ("rules.prepend", overrides.prependRules),
            ("rules.append", overrides.appendRules),
        ]
        for (field, value) in scalars {
            try validateScalar(value, field: field)
        }
        for (field, values) in lists {
            for value in values ?? [] {
                try validateScalar(value, field: field)
            }
        }
    }

    private func validateScalar(_ value: String?, field: String) throws {
        if let value, value.contains(where: { $0 == "\n" || $0 == "\r" || $0 == "\0" }) {
            throw RuntimeOverrideValidationError.invalidScalar(field: field)
        }
    }
}
