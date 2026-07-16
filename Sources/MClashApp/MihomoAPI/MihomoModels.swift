import Foundation

public struct MihomoVersion: Codable, Equatable, Sendable {
    public let meta: Bool
    public let version: String

    public init(meta: Bool, version: String) {
        self.meta = meta
        self.version = version
    }
}

public struct MihomoConfig: Codable, Equatable, Sendable {
    public let port: Int
    public let socksPort: Int
    public let redirPort: Int
    public let tproxyPort: Int
    public let mixedPort: Int
    public let tun: MihomoTUNConfig
    public let authentication: [String]?
    public let skipAuthPrefixes: [String]?
    public let lanAllowedIPs: [String]?
    public let lanDisallowedIPs: [String]?
    public let allowLAN: Bool
    public let bindAddress: String
    public let mode: String
    public let unifiedDelay: Bool
    public let logLevel: String
    public let ipv6: Bool
    public let interfaceName: String
    public let routingMark: Int
    public let geoXURL: MihomoGeoXURL?
    public let geoAutoUpdate: Bool?
    public let geoUpdateInterval: Int?
    public let geodataMode: Bool?
    public let geodataLoader: String?
    public let geositeMatcher: String?
    public let tcpConcurrent: Bool
    public let findProcessMode: String
    public let sniffing: Bool
    public let globalUserAgent: String?
    public let etagSupport: Bool?
    public let keepAliveIdle: Int?
    public let keepAliveInterval: Int?
    public let disableKeepAlive: Bool?

    enum CodingKeys: String, CodingKey {
        case port
        case socksPort = "socks-port"
        case redirPort = "redir-port"
        case tproxyPort = "tproxy-port"
        case mixedPort = "mixed-port"
        case tun
        case authentication
        case skipAuthPrefixes = "skip-auth-prefixes"
        case lanAllowedIPs = "lan-allowed-ips"
        case lanDisallowedIPs = "lan-disallowed-ips"
        case allowLAN = "allow-lan"
        case bindAddress = "bind-address"
        case mode
        case unifiedDelay = "unified-delay"
        case logLevel = "log-level"
        case ipv6
        case interfaceName = "interface-name"
        case routingMark = "routing-mark"
        case geoXURL = "geox-url"
        case geoAutoUpdate = "geo-auto-update"
        case geoUpdateInterval = "geo-update-interval"
        case geodataMode = "geodata-mode"
        case geodataLoader = "geodata-loader"
        case geositeMatcher = "geosite-matcher"
        case tcpConcurrent = "tcp-concurrent"
        case findProcessMode = "find-process-mode"
        case sniffing
        case globalUserAgent = "global-ua"
        case etagSupport = "etag-support"
        case keepAliveIdle = "keep-alive-idle"
        case keepAliveInterval = "keep-alive-interval"
        case disableKeepAlive = "disable-keep-alive"
    }
}

public struct MihomoTUNConfig: Codable, Equatable, Sendable {
    public let enable: Bool
    public let device: String
    public let stack: String
    public let dnsHijack: [String]?
    public let autoRoute: Bool
    public let autoDetectInterface: Bool
    public let mtu: UInt32?
    public let strictRoute: Bool?
    public let routeAddresses: [String]?
    public let routeExcludeAddresses: [String]?
    public let includeInterfaces: [String]?
    public let excludeInterfaces: [String]?
    public let endpointIndependentNAT: Bool?
    public let udpTimeout: Int64?
    public let icmpTimeout: Int64?
    public let receiveMessageX: Bool?
    public let sendMessageX: Bool?

    enum CodingKeys: String, CodingKey {
        case enable, device, stack
        case dnsHijack = "dns-hijack"
        case autoRoute = "auto-route"
        case autoDetectInterface = "auto-detect-interface"
        case mtu
        case strictRoute = "strict-route"
        case routeAddresses = "route-address"
        case routeExcludeAddresses = "route-exclude-address"
        case includeInterfaces = "include-interface"
        case excludeInterfaces = "exclude-interface"
        case endpointIndependentNAT = "endpoint-independent-nat"
        case udpTimeout = "udp-timeout"
        case icmpTimeout = "icmp-timeout"
        case receiveMessageX = "recvmsgx"
        case sendMessageX = "sendmsgx"
    }
}

public struct MihomoGeoXURL: Codable, Equatable, Sendable {
    public let geoIP: String
    public let mmdb: String
    public let asn: String
    public let geoSite: String

    enum CodingKeys: String, CodingKey {
        case geoIP = "geo-ip"
        case mmdb, asn
        case geoSite = "geo-site"
    }
}

/// Fields supported by Alpha's `PATCH /configs` endpoint.
///
/// All properties are optional so encoding only changes the fields explicitly set by the caller.
public struct MihomoConfigPatch: Codable, Equatable, Sendable {
    public var port: Int?
    public var socksPort: Int?
    public var redirPort: Int?
    public var tproxyPort: Int?
    public var mixedPort: Int?
    public var tun: MihomoTUNConfigPatch?
    public var allowLAN: Bool?
    public var skipAuthPrefixes: [String]?
    public var lanAllowedIPs: [String]?
    public var lanDisallowedIPs: [String]?
    public var bindAddress: String?
    public var mode: String?
    public var logLevel: String?
    public var ipv6: Bool?
    public var sniffing: Bool?
    public var tcpConcurrent: Bool?
    public var findProcessMode: String?
    public var interfaceName: String?

    public init(
        port: Int? = nil,
        socksPort: Int? = nil,
        redirPort: Int? = nil,
        tproxyPort: Int? = nil,
        mixedPort: Int? = nil,
        tun: MihomoTUNConfigPatch? = nil,
        allowLAN: Bool? = nil,
        skipAuthPrefixes: [String]? = nil,
        lanAllowedIPs: [String]? = nil,
        lanDisallowedIPs: [String]? = nil,
        bindAddress: String? = nil,
        mode: String? = nil,
        logLevel: String? = nil,
        ipv6: Bool? = nil,
        sniffing: Bool? = nil,
        tcpConcurrent: Bool? = nil,
        findProcessMode: String? = nil,
        interfaceName: String? = nil
    ) {
        self.port = port
        self.socksPort = socksPort
        self.redirPort = redirPort
        self.tproxyPort = tproxyPort
        self.mixedPort = mixedPort
        self.tun = tun
        self.allowLAN = allowLAN
        self.skipAuthPrefixes = skipAuthPrefixes
        self.lanAllowedIPs = lanAllowedIPs
        self.lanDisallowedIPs = lanDisallowedIPs
        self.bindAddress = bindAddress
        self.mode = mode
        self.logLevel = logLevel
        self.ipv6 = ipv6
        self.sniffing = sniffing
        self.tcpConcurrent = tcpConcurrent
        self.findProcessMode = findProcessMode
        self.interfaceName = interfaceName
    }

    enum CodingKeys: String, CodingKey {
        case port
        case socksPort = "socks-port"
        case redirPort = "redir-port"
        case tproxyPort = "tproxy-port"
        case mixedPort = "mixed-port"
        case tun
        case allowLAN = "allow-lan"
        case skipAuthPrefixes = "skip-auth-prefixes"
        case lanAllowedIPs = "lan-allowed-ips"
        case lanDisallowedIPs = "lan-disallowed-ips"
        case bindAddress = "bind-address"
        case mode
        case logLevel = "log-level"
        case ipv6, sniffing
        case tcpConcurrent = "tcp-concurrent"
        case findProcessMode = "find-process-mode"
        case interfaceName = "interface-name"
    }
}

public struct MihomoTUNConfigPatch: Codable, Equatable, Sendable {
    public var enable: Bool?
    public var device: String?
    public var stack: String?
    public var dnsHijack: [String]?
    public var autoRoute: Bool?
    public var autoDetectInterface: Bool?
    public var mtu: UInt32?
    public var strictRoute: Bool?
    public var routeAddresses: [String]?
    public var routeExcludeAddresses: [String]?

    public init(
        enable: Bool? = nil,
        device: String? = nil,
        stack: String? = nil,
        dnsHijack: [String]? = nil,
        autoRoute: Bool? = nil,
        autoDetectInterface: Bool? = nil,
        mtu: UInt32? = nil,
        strictRoute: Bool? = nil,
        routeAddresses: [String]? = nil,
        routeExcludeAddresses: [String]? = nil
    ) {
        self.enable = enable
        self.device = device
        self.stack = stack
        self.dnsHijack = dnsHijack
        self.autoRoute = autoRoute
        self.autoDetectInterface = autoDetectInterface
        self.mtu = mtu
        self.strictRoute = strictRoute
        self.routeAddresses = routeAddresses
        self.routeExcludeAddresses = routeExcludeAddresses
    }

    enum CodingKeys: String, CodingKey {
        case enable, device, stack
        case dnsHijack = "dns-hijack"
        case autoRoute = "auto-route"
        case autoDetectInterface = "auto-detect-interface"
        case mtu
        case strictRoute = "strict-route"
        case routeAddresses = "route-address"
        case routeExcludeAddresses = "route-exclude-address"
    }
}

public struct MihomoRuleCollection: Codable, Equatable, Sendable {
    public let rules: [MihomoRule]
}

public struct MihomoRule: Codable, Equatable, Sendable {
    public let index: Int
    public let type: String
    public let payload: String
    public let proxy: String
    public let size: Int
    public let extra: MihomoRuleExtra?
}

public struct MihomoRuleExtra: Codable, Equatable, Sendable {
    public let disabled: Bool
    public let hitCount: UInt64
    public let hitAt: String
    public let missCount: UInt64
    public let missAt: String
}

public struct MihomoProxyCollection: Codable, Equatable, Sendable {
    public let proxies: [String: MihomoProxy]

    public init(proxies: [String: MihomoProxy]) {
        self.proxies = proxies
    }
}

public struct MihomoProxy: Codable, Equatable, Sendable, Identifiable {
    public let id: String?
    public let name: String
    public let type: String
    public let udp: Bool
    public let udpOverTCP: Bool
    public let xudp: Bool
    public let tcpFastOpen: Bool
    public let multipathTCP: Bool
    public let smux: Bool
    public let interface: String?
    public let routingMark: Int?
    public let providerName: String?
    public let dialerProxy: String?
    public let alive: Bool
    public let history: [MihomoDelayHistory]
    public let extraDelayHistories: [String: MihomoProxyState]
    public let all: [String]
    public let now: String?
    public let testURL: String?
    public let expectedStatus: String?
    public let fixed: String?
    public let hidden: Bool
    public let icon: String?
    public let emptyFallback: String?

    enum CodingKeys: String, CodingKey {
        case id, name, type, udp, xudp, smux, alive, history, all, now, fixed, hidden, icon, interface
        case udpOverTCP = "uot"
        case tcpFastOpen = "tfo"
        case multipathTCP = "mptcp"
        case routingMark = "routing-mark"
        case providerName = "provider-name"
        case dialerProxy = "dialer-proxy"
        case extraDelayHistories = "extra"
        case testURL = "testUrl"
        case expectedStatus
        case emptyFallback
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        type = try container.decode(String.self, forKey: .type)
        udp = try container.decodeIfPresent(Bool.self, forKey: .udp) ?? false
        udpOverTCP = try container.decodeIfPresent(Bool.self, forKey: .udpOverTCP) ?? false
        xudp = try container.decodeIfPresent(Bool.self, forKey: .xudp) ?? false
        tcpFastOpen = try container.decodeIfPresent(Bool.self, forKey: .tcpFastOpen) ?? false
        multipathTCP = try container.decodeIfPresent(Bool.self, forKey: .multipathTCP) ?? false
        smux = try container.decodeIfPresent(Bool.self, forKey: .smux) ?? false
        interface = try container.decodeIfPresent(String.self, forKey: .interface)
        routingMark = try container.decodeIfPresent(Int.self, forKey: .routingMark)
        providerName = try container.decodeIfPresent(String.self, forKey: .providerName)
        dialerProxy = try container.decodeIfPresent(String.self, forKey: .dialerProxy)
        alive = try container.decodeIfPresent(Bool.self, forKey: .alive) ?? true
        history = try container.decodeIfPresent([MihomoDelayHistory].self, forKey: .history) ?? []
        extraDelayHistories = try container.decodeIfPresent(
            [String: MihomoProxyState].self,
            forKey: .extraDelayHistories
        ) ?? [:]
        all = try container.decodeIfPresent([String].self, forKey: .all) ?? []
        now = try container.decodeIfPresent(String.self, forKey: .now)
        testURL = try container.decodeIfPresent(String.self, forKey: .testURL)
        expectedStatus = try container.decodeIfPresent(String.self, forKey: .expectedStatus)
        fixed = try container.decodeIfPresent(String.self, forKey: .fixed)
        hidden = try container.decodeIfPresent(Bool.self, forKey: .hidden) ?? false
        icon = try container.decodeIfPresent(String.self, forKey: .icon)
        emptyFallback = try container.decodeIfPresent(String.self, forKey: .emptyFallback)
    }
}

public struct MihomoDelayHistory: Codable, Equatable, Sendable {
    public let time: String
    public let delay: Int
}

public struct MihomoProxyState: Codable, Equatable, Sendable {
    public let alive: Bool
    public let history: [MihomoDelayHistory]?
}

public struct MihomoDelayResult: Codable, Equatable, Sendable {
    public let delay: Int
}

public struct MihomoProxyProviderCollection: Codable, Equatable, Sendable {
    public let providers: [String: MihomoProxyProvider]
}

public struct MihomoProxyProvider: Codable, Equatable, Sendable {
    public let name: String
    public let type: String
    public let vehicleType: String
    public let proxies: [MihomoProxy]
    public let testURL: String
    public let expectedStatus: String
    public let updatedAt: String?
    public let subscriptionInfo: MihomoSubscriptionInfo?

    enum CodingKeys: String, CodingKey {
        case name, type, vehicleType, proxies, expectedStatus, updatedAt, subscriptionInfo
        case testURL = "testUrl"
    }
}

public struct MihomoSubscriptionInfo: Codable, Equatable, Sendable {
    public let upload: Int64
    public let download: Int64
    public let total: Int64
    public let expire: Int64

    enum CodingKeys: String, CodingKey {
        case upload = "Upload"
        case download = "Download"
        case total = "Total"
        case expire = "Expire"
    }
}

public struct MihomoRuleProviderCollection: Codable, Equatable, Sendable {
    public let providers: [String: MihomoRuleProvider]
}

public struct MihomoRuleProvider: Codable, Equatable, Sendable {
    public let behavior: String
    public let format: String
    public let name: String
    public let ruleCount: Int
    public let type: String
    public let vehicleType: String
    public let updatedAt: String
    public let payload: [String]?
}

public struct MihomoTraffic: Codable, Equatable, Sendable {
    public let upload: Int64
    public let download: Int64
    public let uploadTotal: Int64
    public let downloadTotal: Int64

    enum CodingKeys: String, CodingKey {
        case upload = "up"
        case download = "down"
        case uploadTotal = "upTotal"
        case downloadTotal = "downTotal"
    }
}

public enum MihomoLogLevel: String, Codable, CaseIterable, Sendable {
    case debug
    case info
    case warning
    case error
    case silent
}

public struct MihomoLogEntry: Codable, Equatable, Sendable {
    public let type: String
    public let payload: String
}

public struct MihomoStructuredLogEntry: Codable, Equatable, Sendable {
    public let time: String
    public let level: String
    public let message: String
    public let fields: [MihomoStructuredLogField]
}

public struct MihomoStructuredLogField: Codable, Equatable, Sendable {
    public let key: String
    public let value: String
}

public struct MihomoConnectionSnapshot: Codable, Equatable, Sendable {
    public let downloadTotal: Int64
    public let uploadTotal: Int64
    public let connections: [MihomoConnection]
    public let memory: UInt64?

    enum CodingKeys: String, CodingKey {
        case downloadTotal, uploadTotal, connections, memory
    }

    public init(
        downloadTotal: Int64,
        uploadTotal: Int64,
        connections: [MihomoConnection],
        memory: UInt64?
    ) {
        self.downloadTotal = downloadTotal
        self.uploadTotal = uploadTotal
        self.connections = connections
        self.memory = memory
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        downloadTotal = try container.decode(Int64.self, forKey: .downloadTotal)
        uploadTotal = try container.decode(Int64.self, forKey: .uploadTotal)
        connections = try container.decodeIfPresent([MihomoConnection].self, forKey: .connections) ?? []
        memory = try container.decodeIfPresent(UInt64.self, forKey: .memory)
    }
}

public struct MihomoConnection: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let metadata: MihomoConnectionMetadata
    public let upload: Int64
    public let download: Int64
    public let start: String
    public let chains: [String]
    public let providerChains: [String]
    public let rule: String
    public let rulePayload: String

    enum CodingKeys: String, CodingKey {
        case id, metadata, upload, download, start, chains, rule, rulePayload
        case providerChains
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        metadata = try container.decode(MihomoConnectionMetadata.self, forKey: .metadata)
        upload = try container.decode(Int64.self, forKey: .upload)
        download = try container.decode(Int64.self, forKey: .download)
        start = try container.decode(String.self, forKey: .start)
        chains = try container.decodeIfPresent([String].self, forKey: .chains) ?? []
        providerChains = try container.decodeIfPresent([String].self, forKey: .providerChains) ?? []
        rule = try container.decodeIfPresent(String.self, forKey: .rule) ?? ""
        rulePayload = try container.decodeIfPresent(String.self, forKey: .rulePayload) ?? ""
    }
}

public struct MihomoConnectionMetadata: Codable, Equatable, Sendable {
    public let network: String?
    public let type: String?
    public let sourceIP: String?
    public let destinationIP: String?
    public let sourceGeoIP: [String]?
    public let destinationGeoIP: [String]?
    public let sourceIPASN: String?
    public let destinationIPASN: String?
    public let sourcePort: String?
    public let destinationPort: String?
    public let inboundIP: String?
    public let inboundPort: String?
    public let inboundName: String?
    public let inboundUser: String?
    public let host: String?
    public let dnsMode: String?
    public let uid: UInt32?
    public let process: String?
    public let processPath: String?
    public let specialProxy: String?
    public let specialRules: String?
    public let remoteDestination: String?
    public let sniffHost: String?
}
