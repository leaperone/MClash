import CryptoKit
import Foundation
import MClashNetworkShared

// MARK: - Stable identifiers

public protocol ConfigurationIdentifier: RawRepresentable, Codable, Hashable, Sendable
where RawValue == UUID {}

public extension ConfigurationIdentifier {
    /// Stable UUID derived from a SHA-256 fingerprint. Provider-controlled
    /// display names are intentionally not part of the identity material.
    static func stable(for fingerprint: String) -> Self {
        let bytes = Array(SHA256.hash(data: Data(fingerprint.utf8)).prefix(16))
        let uuid = UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
        ))
        return Self(rawValue: uuid)!
    }
}

public struct SourceID: ConfigurationIdentifier { public let rawValue: UUID; public init(rawValue: UUID = UUID()) { self.rawValue = rawValue } }
public struct NodeID: ConfigurationIdentifier { public let rawValue: UUID; public init(rawValue: UUID = UUID()) { self.rawValue = rawValue } }
public struct ProxyGroupID: ConfigurationIdentifier { public let rawValue: UUID; public init(rawValue: UUID = UUID()) { self.rawValue = rawValue } }
public struct RoutingRuleID: ConfigurationIdentifier { public let rawValue: UUID; public init(rawValue: UUID = UUID()) { self.rawValue = rawValue } }
public struct RuleSetID: ConfigurationIdentifier { public let rawValue: UUID; public init(rawValue: UUID = UUID()) { self.rawValue = rawValue } }
public struct DNSPolicyID: ConfigurationIdentifier { public let rawValue: UUID; public init(rawValue: UUID = UUID()) { self.rawValue = rawValue } }
public struct EntranceID: ConfigurationIdentifier { public let rawValue: UUID; public init(rawValue: UUID = UUID()) { self.rawValue = rawValue } }
public struct WorkspaceID: ConfigurationIdentifier { public let rawValue: UUID; public init(rawValue: UUID = UUID()) { self.rawValue = rawValue } }
public struct RuntimeSnapshotID: ConfigurationIdentifier { public let rawValue: UUID; public init(rawValue: UUID = UUID()) { self.rawValue = rawValue } }

// MARK: - Source and node catalog

public enum ConfigurationSourceKind: String, Codable, CaseIterable, Sendable { case subscription, localFile, pastedConfig }
public struct Source: Codable, Hashable, Identifiable, Sendable {
    public let id: SourceID
    public var kind: ConfigurationSourceKind
    public var displayName: String
    public var location: String
    public var revision: Int
    public var lastFetchedAt: Date?
    public var lastSuccessfulParseAt: Date?
    public var rawSnapshotReference: String?
    public var parseDiagnostics: [ConfigurationDiagnostic]
    public init(id: SourceID = SourceID(), kind: ConfigurationSourceKind, displayName: String, location: String = "", revision: Int = 0, lastFetchedAt: Date? = nil, lastSuccessfulParseAt: Date? = nil, rawSnapshotReference: String? = nil, parseDiagnostics: [ConfigurationDiagnostic] = []) {
        self.id = id; self.kind = kind; self.displayName = displayName; self.location = location; self.revision = max(0, revision); self.lastFetchedAt = lastFetchedAt; self.lastSuccessfulParseAt = lastSuccessfulParseAt; self.rawSnapshotReference = rawSnapshotReference; self.parseDiagnostics = parseDiagnostics
    }
}

public enum NodeProtocol: String, Codable, CaseIterable, Sendable { case http, https, socks5, shadowsocks, vmess, vless, trojan, hysteria, hysteria2, tuic, wireguard, ssh, unknown }
public enum NodeAvailability: String, Codable, CaseIterable, Sendable { case unknown, available, unavailable, sourceRemoved, unsupported }
public struct NodeHealthSnapshot: Codable, Hashable, Sendable {
    public var availability: NodeAvailability
    public var latencyMilliseconds: Int?
    public var checkedAt: Date?
    public init(availability: NodeAvailability = .unknown, latencyMilliseconds: Int? = nil, checkedAt: Date? = nil) { self.availability = availability; self.latencyMilliseconds = latencyMilliseconds; self.checkedAt = checkedAt }
}

public struct Node: Codable, Hashable, Identifiable, Sendable {
    public let id: NodeID
    public let fingerprint: String
    public var displayName: String
    public var proto: NodeProtocol
    public var host: String
    public var port: Int
    public var parameters: [String: String]
    public var sourceLinks: [SourceID]
    /// The last authoritative refresh generation in which each source
    /// advertised this node. This is deliberately separate from `sourceLinks`:
    /// links describe current ownership while generations make reconciliation
    /// auditable and prevent a stale/partial refresh from looking current.
    /// Missing entries are treated as legacy data and are backfilled by the
    /// source synchronizer.
    public var sourceRevisionByID: [SourceID: Int]
    public var tags: Set<String>
    public var region: String?
    public var enabled: Bool
    public var health: NodeHealthSnapshot
    public var userAlias: String?
    public var lastSeenAt: Date?

    /// Full connection material for diagnostics. The persisted `id` and
    /// `fingerprint` deliberately do not change when provider credentials
    /// rotate during a refresh.
    public var connectionFingerprint: String {
        Self.makeConnectionFingerprint(protocol: proto, host: host, port: port, parameters: parameters)
    }

    /// Connector-neutral projection used by native outbound implementations.
    /// The projection preserves transport parameters but does not expose the
    /// node's stable identity or source metadata to the connector layer.
    public var outboundTarget: OutboundNodeTarget? {
        try? OutboundNodeTarget(
            protocolName: proto.rawValue,
            host: host,
            port: UInt16(port),
            parameters: parameters
        )
    }

    public init(id: NodeID = NodeID(), displayName: String, protocol proto: NodeProtocol, host: String, port: Int, parameters: [String: String] = [:], sourceLinks: [SourceID] = [], sourceRevisionByID: [SourceID: Int] = [:], tags: Set<String> = [], region: String? = nil, enabled: Bool = true, health: NodeHealthSnapshot = NodeHealthSnapshot(), userAlias: String? = nil, lastSeenAt: Date? = nil) throws {
        let normalizedHost = Self.normalizeHost(host)
        guard !normalizedHost.isEmpty, (1...65535).contains(port) else { throw ConfigurationModelError.invalidNodeEndpoint(host: host, port: port) }
        self.id = id; self.displayName = displayName; self.proto = proto; self.host = normalizedHost; self.port = port; self.parameters = parameters; self.sourceLinks = sourceLinks; self.sourceRevisionByID = sourceRevisionByID.filter { $0.value >= 0 }; self.tags = tags; self.region = region; self.enabled = enabled; self.health = health; self.userAlias = userAlias; self.lastSeenAt = lastSeenAt
        self.fingerprint = Self.makeFingerprint(protocol: proto, host: normalizedHost, port: port, parameters: parameters)
    }

    private enum CodingKeys: String, CodingKey {
        case id, fingerprint, displayName, proto, host, port, parameters, sourceLinks,
             sourceRevisionByID, tags, region, enabled, health, userAlias, lastSeenAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let id = try container.decode(NodeID.self, forKey: .id)
        let displayName = try container.decode(String.self, forKey: .displayName)
        let proto = try container.decode(NodeProtocol.self, forKey: .proto)
        let host = try container.decode(String.self, forKey: .host)
        let port = try container.decode(Int.self, forKey: .port)
        let parameters = try container.decode([String: String].self, forKey: .parameters)
        let sourceLinks = try container.decodeIfPresent([SourceID].self, forKey: .sourceLinks) ?? []
        let revisions = try container.decodeIfPresent([SourceID: Int].self, forKey: .sourceRevisionByID) ?? [:]
        let tags = try container.decodeIfPresent(Set<String>.self, forKey: .tags) ?? []
        let region = try container.decodeIfPresent(String.self, forKey: .region)
        let enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        let health = try container.decodeIfPresent(NodeHealthSnapshot.self, forKey: .health) ?? NodeHealthSnapshot()
        let userAlias = try container.decodeIfPresent(String.self, forKey: .userAlias)
        let lastSeenAt = try container.decodeIfPresent(Date.self, forKey: .lastSeenAt)
        try self.init(id: id, displayName: displayName, protocol: proto, host: host, port: port,
                      parameters: parameters, sourceLinks: sourceLinks,
                      sourceRevisionByID: revisions, tags: tags, region: region,
                      enabled: enabled, health: health, userAlias: userAlias, lastSeenAt: lastSeenAt)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(fingerprint, forKey: .fingerprint)
        try container.encode(displayName, forKey: .displayName)
        try container.encode(proto, forKey: .proto)
        try container.encode(host, forKey: .host)
        try container.encode(port, forKey: .port)
        try container.encode(parameters, forKey: .parameters)
        try container.encode(sourceLinks, forKey: .sourceLinks)
        try container.encode(sourceRevisionByID, forKey: .sourceRevisionByID)
        try container.encode(tags, forKey: .tags)
        try container.encodeIfPresent(region, forKey: .region)
        try container.encode(enabled, forKey: .enabled)
        try container.encode(health, forKey: .health)
        try container.encodeIfPresent(userAlias, forKey: .userAlias)
        try container.encodeIfPresent(lastSeenAt, forKey: .lastSeenAt)
    }

    public static func makeFingerprint(protocol proto: NodeProtocol, host: String, port: Int, parameters: [String: String]) -> String {
        // Credentials rotate frequently in subscriptions.  They are not a
        // node identity: retaining them here would make every refresh create
        // a new node and orphan user-maintained group membership.  The
        // credential values still remain in `parameters` and are emitted to
        // Mihomo; only the identity material excludes them.
        let fields = parameters
            .compactMap { key, value -> (String, String)? in
                let normalizedKey = NodeIdentity.normalizeParameterKey(key)
                guard !NodeIdentity.isCredentialParameter(normalizedKey),
                      !NodeIdentity.isPresentationParameter(normalizedKey) else { return nil }
                return (
                    normalizedKey,
                    NodeIdentity.normalizeParameterValue(key: normalizedKey, value: value)
                )
            }
            .sorted { lhs, rhs in
                lhs.0 == rhs.0 ? lhs.1 < rhs.1 : lhs.0 < rhs.0
            }
            .map { pair in pair.0 + "=" + pair.1 }
            .joined(separator: "&")
        let material = "\(proto.rawValue)|\(normalizeHost(host))|\(port)|\(fields)"
        return SHA256.hash(data: Data(material.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Full connection material, including credentials, for diagnostics only.
    /// It must never be used as the persisted NodeID because providers rotate
    /// these values during an otherwise identical subscription refresh.
    public static func makeConnectionFingerprint(protocol proto: NodeProtocol, host: String, port: Int, parameters: [String: String]) -> String {
        let normalizedParameters = parameters.compactMap { key, value -> (String, String)? in
            let normalizedKey = NodeIdentity.normalizeParameterKey(key)
            guard !NodeIdentity.isPresentationParameter(normalizedKey) else { return nil }
            return (
                normalizedKey,
                NodeIdentity.normalizeParameterValue(key: key, value: value)
            )
        }.sorted { lhs, rhs in
            if lhs.0 == rhs.0 { return lhs.1 < rhs.1 }
            return lhs.0 < rhs.0
        }
        let fields = normalizedParameters.map { pair in
            pair.0 + "=" + pair.1
        }.joined(separator: "&")
        let normalizedHost = normalizeHost(host)
        let material = "\(proto.rawValue)|\(normalizedHost)|\(port)|\(fields)"
        return SHA256.hash(data: Data(material.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func normalizeHost(_ value: String) -> String {
        var normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if normalized.first == "[", normalized.last == "]" {
            normalized.removeFirst()
            normalized.removeLast()
        }
        return normalized.trimmingCharacters(in: CharacterSet(charactersIn: "."))
    }
}

// MARK: - Policy objects

public enum ProxyGroupType: String, Codable, CaseIterable, Sendable { case select, fallback, urlTest, loadBalance, direct, reject, relay }
public enum ProxyGroupMember: Codable, Hashable, Sendable { case node(NodeID), group(ProxyGroupID) }
public struct ProxyGroup: Codable, Hashable, Identifiable, Sendable {
    public let id: ProxyGroupID
    public var name: String
    public var type: ProxyGroupType
    /// Explicit members are durable pins. Selectors are evaluated on every
    /// source refresh and are intentionally kept separate from those pins.
    public var members: [ProxyGroupMember]
    public var memberSelectors: [NodeSelector]
    public var enabled: Bool

    public init(id: ProxyGroupID = ProxyGroupID(), name: String, type: ProxyGroupType = .select, members: [ProxyGroupMember] = [], memberSelectors: [NodeSelector] = [], enabled: Bool = true) {
        self.id=id; self.name=name; self.type=type; self.members=members; self.memberSelectors=memberSelectors; self.enabled=enabled
    }

    private enum CodingKeys: String, CodingKey { case id, name, type, members, memberSelectors, enabled }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(id: try c.decode(ProxyGroupID.self, forKey: .id), name: try c.decode(String.self, forKey: .name), type: try c.decode(ProxyGroupType.self, forKey: .type), members: try c.decodeIfPresent([ProxyGroupMember].self, forKey: .members) ?? [], memberSelectors: try c.decodeIfPresent([NodeSelector].self, forKey: .memberSelectors) ?? [], enabled: try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id); try c.encode(name, forKey: .name); try c.encode(type, forKey: .type); try c.encode(members, forKey: .members); try c.encode(memberSelectors, forKey: .memberSelectors); try c.encode(enabled, forKey: .enabled)
    }
}

/// Flat matcher storage maps to CaptureRule fields: different matcher kinds
/// are ANDed, while multiple values within one kind are ORed. The compiler
/// preserves that distinction when producing Mihomo and Network Extension
/// rules.
public enum RoutingMatcher: Codable, Hashable, Sendable {
    case application(String)
    case processPath(String)
    case processName(String)
    case userID(UInt32)
    case domainExact(String)
    case domainSuffix(String)
    case domainWildcard(String)
    case ipCIDR(String)
    case geoIP(String)
    /// Kept for decoding older drafts, but rejected by the validator because
    /// the bundled Mihomo Alpha core has no GEOIP6 rule type. Use IP-CIDR6.
    case geoIP6(String)
    case geoSite(String)
    case transport(String)
    case port(Int)
    case portRange(ClosedRange<Int>)
}
public enum RoutingAction: Codable, Hashable, Sendable { case direct, reject, proxyGroup(ProxyGroupID) }
public enum UnavailableNodeFallback: String, Codable, Sendable { case direct, reject }
extension UnavailableNodeFallback {
    private enum LegacyObjectKey: String, CodingKey { case direct, reject }

    /// Older manifests encoded this as a zero-payload object (`{"direct":{}}`)
    /// before it became a string enum. Both shapes must decode, otherwise an
    /// upgrade quarantines the whole strategy document.
    public init(from decoder: Decoder) throws {
        if let container = try? decoder.singleValueContainer(),
           let raw = try? container.decode(String.self) {
            guard let value = Self(rawValue: raw) else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Unsupported unavailable-node fallback \(raw)"
                )
            }
            self = value
            return
        }
        let object = try decoder.container(keyedBy: LegacyObjectKey.self)
        if object.contains(.direct) {
            self = .direct
        } else if object.contains(.reject) {
            self = .reject
        } else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "Unsupported unavailable-node fallback"
                )
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}
public enum ConfigurationRoutingMode: String, Codable, CaseIterable, Sendable {
    case rule
    case global
    case direct
}

/// Mihomo's implicit policy targets. They are stable runtime placeholders, not
/// imported source groups and therefore do not need a user-created object.
public enum ConfigurationBuiltInPolicy: String, Codable, CaseIterable, Sendable {
    case global = "GLOBAL"
    case direct = "DIRECT"
    case reject = "REJECT"
}

public struct RoutingRule: Codable, Hashable, Identifiable, Sendable { public let id: RoutingRuleID; public var enabled: Bool; public var priority: Int; public var matchers: [RoutingMatcher]; public var action: RoutingAction; public var unavailableFallback: UnavailableNodeFallback; public var workspaceScope: WorkspaceID?; public init(id: RoutingRuleID = RoutingRuleID(), enabled: Bool = true, priority: Int, matchers: [RoutingMatcher] = [], action: RoutingAction, unavailableFallback: UnavailableNodeFallback = .direct, workspaceScope: WorkspaceID? = nil) { self.id=id; self.enabled=enabled; self.priority=priority; self.matchers=matchers; self.action=action; self.unavailableFallback=unavailableFallback; self.workspaceScope=workspaceScope } }
extension RoutingRule {
    private enum CodingKeys: String, CodingKey {
        case id, enabled, priority, matchers, action, unavailableFallback, workspaceScope
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decode(RoutingRuleID.self, forKey: .id),
            enabled: try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true,
            priority: try container.decode(Int.self, forKey: .priority),
            matchers: try container.decodeIfPresent([RoutingMatcher].self, forKey: .matchers) ?? [],
            action: try container.decode(RoutingAction.self, forKey: .action),
            unavailableFallback: try container.decodeIfPresent(UnavailableNodeFallback.self, forKey: .unavailableFallback) ?? .direct,
            workspaceScope: try container.decodeIfPresent(WorkspaceID.self, forKey: .workspaceScope)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(enabled, forKey: .enabled)
        try container.encode(priority, forKey: .priority)
        try container.encode(matchers, forKey: .matchers)
        try container.encode(action, forKey: .action)
        try container.encode(unavailableFallback, forKey: .unavailableFallback)
        try container.encodeIfPresent(workspaceScope, forKey: .workspaceScope)
    }
}
public enum RuleSetBehavior: String, Codable, CaseIterable, Sendable {
    case classical
    case domain
    case ipcidr
}

public enum RuleSetFormat: String, Codable, CaseIterable, Sendable {
    case yaml
    case text
    case mrs
}

/// A MClash-owned rule set.  A source Profile can mention rule providers, but
/// those declarations are never copied into this model automatically; users
/// explicitly add a provider here and choose its behavior/format/path.
public struct RuleSet: Codable, Hashable, Identifiable, Sendable {
    public let id: RuleSetID
    public var name: String
    public var sourceURL: URL?
    public var rules: [String]
    public var defaultAction: RoutingAction
    public var behavior: RuleSetBehavior
    public var format: RuleSetFormat
    public var path: String?
    public var enabled: Bool
    public var revision: Int

    public init(
        id: RuleSetID = RuleSetID(),
        name: String,
        sourceURL: URL? = nil,
        rules: [String] = [],
        defaultAction: RoutingAction = .direct,
        behavior: RuleSetBehavior = .classical,
        format: RuleSetFormat = .yaml,
        path: String? = nil,
        enabled: Bool = true,
        revision: Int = 0
    ) {
        self.id = id
        self.name = name
        self.sourceURL = sourceURL
        self.rules = rules
        self.defaultAction = defaultAction
        self.behavior = behavior
        self.format = format
        self.path = path
        self.enabled = enabled
        self.revision = max(0, revision)
    }
}

public enum DNSMode: String, Codable, CaseIterable, Sendable { case system, fakeIP, redirHost }
public struct DNSPolicy: Codable, Hashable, Identifiable, Sendable {
    public let id: DNSPolicyID
    public var name: String
    public var mode: DNSMode
    public var nameservers: [String]
    public var fallbackNameservers: [String]
    public var proxyServer: String?
    public var rules: [String]
    public var takeoverEnabled: Bool
    public var fakeIPRange: String?
    public var fakeIPFilter: [String]
    public var fakeIPMaximumEntries: Int
    public var fakeIPMaximumEntriesPerSource: Int
    public var fakeIPMinimumTTL: TimeInterval
    public var fakeIPMaximumTTL: TimeInterval

    public init(id: DNSPolicyID = DNSPolicyID(), name: String, mode: DNSMode = .system,
                nameservers: [String] = [], fallbackNameservers: [String] = [], proxyServer: String? = nil,
                rules: [String] = [], takeoverEnabled: Bool = false, fakeIPRange: String? = nil,
                fakeIPFilter: [String] = [], fakeIPMaximumEntries: Int = NativeFakeIPConfiguration.maximumEntries,
                fakeIPMaximumEntriesPerSource: Int = NativeFakeIPConfiguration.maximumEntriesPerSource,
                fakeIPMinimumTTL: TimeInterval = 5,
                fakeIPMaximumTTL: TimeInterval = NativeFakeIPConfiguration.maximumTTL) {
        self.id=id; self.name=name; self.mode=mode; self.nameservers=nameservers; self.fallbackNameservers=fallbackNameservers; self.proxyServer=proxyServer; self.rules=rules; self.takeoverEnabled=takeoverEnabled; self.fakeIPRange=fakeIPRange; self.fakeIPFilter=fakeIPFilter; self.fakeIPMaximumEntries=fakeIPMaximumEntries; self.fakeIPMaximumEntriesPerSource=fakeIPMaximumEntriesPerSource; self.fakeIPMinimumTTL=fakeIPMinimumTTL; self.fakeIPMaximumTTL=fakeIPMaximumTTL
    }

    private enum CodingKeys: String, CodingKey { case id, name, mode, nameservers, fallbackNameservers, proxyServer, rules, takeoverEnabled, fakeIPRange, fakeIPFilter, fakeIPMaximumEntries, fakeIPMaximumEntriesPerSource, fakeIPMinimumTTL, fakeIPMaximumTTL }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(id: try c.decode(DNSPolicyID.self, forKey: .id), name: try c.decode(String.self, forKey: .name), mode: try c.decodeIfPresent(DNSMode.self, forKey: .mode) ?? .system, nameservers: try c.decodeIfPresent([String].self, forKey: .nameservers) ?? [], fallbackNameservers: try c.decodeIfPresent([String].self, forKey: .fallbackNameservers) ?? [], proxyServer: try c.decodeIfPresent(String.self, forKey: .proxyServer), rules: try c.decodeIfPresent([String].self, forKey: .rules) ?? [], takeoverEnabled: try c.decodeIfPresent(Bool.self, forKey: .takeoverEnabled) ?? false, fakeIPRange: try c.decodeIfPresent(String.self, forKey: .fakeIPRange), fakeIPFilter: try c.decodeIfPresent([String].self, forKey: .fakeIPFilter) ?? [], fakeIPMaximumEntries: try c.decodeIfPresent(Int.self, forKey: .fakeIPMaximumEntries) ?? NativeFakeIPConfiguration.maximumEntries, fakeIPMaximumEntriesPerSource: try c.decodeIfPresent(Int.self, forKey: .fakeIPMaximumEntriesPerSource) ?? NativeFakeIPConfiguration.maximumEntriesPerSource, fakeIPMinimumTTL: try c.decodeIfPresent(TimeInterval.self, forKey: .fakeIPMinimumTTL) ?? 5, fakeIPMaximumTTL: try c.decodeIfPresent(TimeInterval.self, forKey: .fakeIPMaximumTTL) ?? NativeFakeIPConfiguration.maximumTTL)
    }
}

public extension DNSPolicy {
    var nativeFakeIPConfiguration: NativeFakeIPConfiguration? {
        guard mode == .fakeIP else { return nil }
        let pool = fakeIPRange.flatMap { try? IPNetwork($0) }
        return try? NativeFakeIPConfiguration(pool: pool, filters: fakeIPFilter, maximumEntries: fakeIPMaximumEntries, maximumEntriesPerSource: fakeIPMaximumEntriesPerSource, minimumTTL: fakeIPMinimumTTL, maximumTTL: fakeIPMaximumTTL)
    }
}

public enum EntranceKind: String, Codable, CaseIterable, Sendable { case http, socks5, appRouting, tun }
public struct Entrance: Codable, Hashable, Identifiable, Sendable {
    public let id: EntranceID
    public var name: String
    public var kind: EntranceKind
    public var enabled: Bool
    public var bindAddress: String
    public var port: Int?
    public var defaultAction: RoutingAction
    public var workspaceOverride: WorkspaceID?

    public init(
        id: EntranceID = EntranceID(),
        name: String? = nil,
        kind: EntranceKind,
        enabled: Bool = false,
        bindAddress: String = "127.0.0.1",
        port: Int? = nil,
        defaultAction: RoutingAction = .direct,
        workspaceOverride: WorkspaceID? = nil
    ) {
        self.id = id
        self.kind = kind
        self.name = name?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? name!.trimmingCharacters(in: .whitespacesAndNewlines)
            : Self.defaultName(for: kind)
        self.enabled = enabled
        self.bindAddress = bindAddress
        self.port = port
        self.defaultAction = defaultAction
        self.workspaceOverride = workspaceOverride
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, kind, enabled, bindAddress, port, defaultAction, workspaceOverride
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decode(EntranceID.self, forKey: .id),
            name: try container.decodeIfPresent(String.self, forKey: .name),
            kind: try container.decode(EntranceKind.self, forKey: .kind),
            enabled: try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? false,
            bindAddress: try container.decodeIfPresent(String.self, forKey: .bindAddress) ?? "127.0.0.1",
            port: try container.decodeIfPresent(Int.self, forKey: .port),
            defaultAction: try container.decodeIfPresent(RoutingAction.self, forKey: .defaultAction) ?? .direct,
            workspaceOverride: try container.decodeIfPresent(WorkspaceID.self, forKey: .workspaceOverride)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(kind, forKey: .kind)
        try container.encode(enabled, forKey: .enabled)
        try container.encode(bindAddress, forKey: .bindAddress)
        try container.encodeIfPresent(port, forKey: .port)
        try container.encode(defaultAction, forKey: .defaultAction)
        try container.encodeIfPresent(workspaceOverride, forKey: .workspaceOverride)
    }

    private static func defaultName(for kind: EntranceKind) -> String {
        switch kind {
        case .http: "HTTP"
        case .socks5: "SOCKS5"
        case .appRouting: "App Routing"
        case .tun: "TUN"
        }
    }
}

public struct Workspace: Codable, Hashable, Identifiable, Sendable {
    public let id: WorkspaceID
    public var name: String
    public var nodeIDs: [NodeID]
    public var proxyGroupIDs: [ProxyGroupID]
    public var ruleIDs: [RoutingRuleID]
    public var ruleSetIDs: [RuleSetID]
    public var dnsPolicyID: DNSPolicyID
    public var entranceIDs: [EntranceID]
    /// The mode applied to traffic entering this workspace. Older manifests
    /// omitted this field and therefore migrate safely to the historical rule
    /// behavior.
    public var routingMode: ConfigurationRoutingMode
    /// The group selected by Mihomo's implicit GLOBAL selector when the mode is
    /// global. It is optional for compatibility; activation falls back to the
    /// first stable MClash strategy group.
    public var globalProxyGroupID: ProxyGroupID?
    public var revision: Int

    public init(
        id: WorkspaceID = WorkspaceID(),
        name: String,
        nodeIDs: [NodeID] = [],
        proxyGroupIDs: [ProxyGroupID] = [],
        ruleIDs: [RoutingRuleID] = [],
        ruleSetIDs: [RuleSetID] = [],
        dnsPolicyID: DNSPolicyID,
        entranceIDs: [EntranceID] = [],
        routingMode: ConfigurationRoutingMode = .rule,
        globalProxyGroupID: ProxyGroupID? = nil,
        revision: Int = 0
    ) {
        self.id = id
        self.name = name
        self.nodeIDs = nodeIDs
        self.proxyGroupIDs = proxyGroupIDs
        self.ruleIDs = ruleIDs
        self.ruleSetIDs = ruleSetIDs
        self.dnsPolicyID = dnsPolicyID
        self.entranceIDs = entranceIDs
        self.routingMode = routingMode
        self.globalProxyGroupID = globalProxyGroupID
        self.revision = max(0, revision)
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, nodeIDs, proxyGroupIDs, ruleIDs, ruleSetIDs
        case dnsPolicyID, entranceIDs, routingMode, globalProxyGroupID, revision
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decode(WorkspaceID.self, forKey: .id),
            name: try container.decode(String.self, forKey: .name),
            nodeIDs: try container.decodeIfPresent([NodeID].self, forKey: .nodeIDs) ?? [],
            proxyGroupIDs: try container.decodeIfPresent([ProxyGroupID].self, forKey: .proxyGroupIDs) ?? [],
            ruleIDs: try container.decodeIfPresent([RoutingRuleID].self, forKey: .ruleIDs) ?? [],
            ruleSetIDs: try container.decodeIfPresent([RuleSetID].self, forKey: .ruleSetIDs) ?? [],
            dnsPolicyID: try container.decode(DNSPolicyID.self, forKey: .dnsPolicyID),
            entranceIDs: try container.decodeIfPresent([EntranceID].self, forKey: .entranceIDs) ?? [],
            routingMode: try container.decodeIfPresent(ConfigurationRoutingMode.self, forKey: .routingMode) ?? .rule,
            globalProxyGroupID: try container.decodeIfPresent(ProxyGroupID.self, forKey: .globalProxyGroupID),
            revision: try container.decodeIfPresent(Int.self, forKey: .revision) ?? 0
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(nodeIDs, forKey: .nodeIDs)
        try container.encode(proxyGroupIDs, forKey: .proxyGroupIDs)
        try container.encode(ruleIDs, forKey: .ruleIDs)
        try container.encode(ruleSetIDs, forKey: .ruleSetIDs)
        try container.encode(dnsPolicyID, forKey: .dnsPolicyID)
        try container.encode(entranceIDs, forKey: .entranceIDs)
        try container.encode(routingMode, forKey: .routingMode)
        try container.encodeIfPresent(globalProxyGroupID, forKey: .globalProxyGroupID)
        try container.encode(revision, forKey: .revision)
    }
}

public struct RuntimeSnapshot: Codable, Hashable, Identifiable, Sendable { public let id: RuntimeSnapshotID; public let workspaceID: WorkspaceID; public let workspaceRevision: Int; public let compilerVersion: String; public let mihomoConfigHash: String; public let generatedAt: Date; public let entranceIDs: [EntranceID]; public let previousSnapshotID: RuntimeSnapshotID?; public var applicationSucceeded: Bool; public init(id: RuntimeSnapshotID = RuntimeSnapshotID(), workspaceID: WorkspaceID, workspaceRevision: Int, compilerVersion: String, mihomoConfigHash: String, generatedAt: Date = Date(), entranceIDs: [EntranceID] = [], previousSnapshotID: RuntimeSnapshotID? = nil, applicationSucceeded: Bool = false) { self.id=id; self.workspaceID=workspaceID; self.workspaceRevision=workspaceRevision; self.compilerVersion=compilerVersion; self.mihomoConfigHash=mihomoConfigHash; self.generatedAt=generatedAt; self.entranceIDs=entranceIDs; self.previousSnapshotID=previousSnapshotID; self.applicationSucceeded=applicationSucceeded } }

extension RuleSet {
    private enum CodingKeys: String, CodingKey {
        case id, name, sourceURL, rules, defaultAction, behavior, format, path, enabled, revision
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decode(RuleSetID.self, forKey: .id),
            name: try container.decode(String.self, forKey: .name),
            sourceURL: try container.decodeIfPresent(URL.self, forKey: .sourceURL),
            rules: try container.decodeIfPresent([String].self, forKey: .rules) ?? [],
            defaultAction: try container.decodeIfPresent(RoutingAction.self, forKey: .defaultAction) ?? .direct,
            behavior: try container.decodeIfPresent(RuleSetBehavior.self, forKey: .behavior) ?? .classical,
            format: try container.decodeIfPresent(RuleSetFormat.self, forKey: .format) ?? .yaml,
            path: try container.decodeIfPresent(String.self, forKey: .path),
            enabled: try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true,
            revision: try container.decodeIfPresent(Int.self, forKey: .revision) ?? 0
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encodeIfPresent(sourceURL, forKey: .sourceURL)
        try container.encode(rules, forKey: .rules)
        try container.encode(defaultAction, forKey: .defaultAction)
        try container.encode(behavior, forKey: .behavior)
        try container.encode(format, forKey: .format)
        try container.encodeIfPresent(path, forKey: .path)
        try container.encode(enabled, forKey: .enabled)
        try container.encode(revision, forKey: .revision)
    }
}
