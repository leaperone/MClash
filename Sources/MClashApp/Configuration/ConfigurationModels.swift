import CryptoKit
import Foundation

// MARK: - Stable identifiers

public protocol ConfigurationIdentifier: RawRepresentable, Codable, Hashable, Sendable
where RawValue == UUID {}

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

    public init(id: NodeID = NodeID(), displayName: String, protocol proto: NodeProtocol, host: String, port: Int, parameters: [String: String] = [:], sourceLinks: [SourceID] = [], tags: Set<String> = [], region: String? = nil, enabled: Bool = true, health: NodeHealthSnapshot = NodeHealthSnapshot(), userAlias: String? = nil, lastSeenAt: Date? = nil) throws {
        let normalizedHost = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard !normalizedHost.isEmpty, (1...65535).contains(port) else { throw ConfigurationModelError.invalidNodeEndpoint(host: host, port: port) }
        self.id = id; self.displayName = displayName; self.proto = proto; self.host = normalizedHost; self.port = port; self.parameters = parameters; self.sourceLinks = sourceLinks; self.tags = tags; self.region = region; self.enabled = enabled; self.health = health; self.userAlias = userAlias; self.lastSeenAt = lastSeenAt
        self.fingerprint = Self.makeFingerprint(protocol: proto, host: normalizedHost, port: port, parameters: parameters)
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
                guard !NodeIdentity.isCredentialParameter(normalizedKey) else { return nil }
                return (normalizedKey, value)
            }
            .sorted { lhs, rhs in
                lhs.0 == rhs.0 ? lhs.1 < rhs.1 : lhs.0 < rhs.0
            }
            .map { pair in pair.0 + "=" + pair.1 }
            .joined(separator: "&")
        let material = "\(proto.rawValue)|\(host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")))|\(port)|\(fields)"
        return SHA256.hash(data: Data(material.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Full connection material, including credentials, for diagnostics only.
    /// It must never be used as the persisted NodeID because providers rotate
    /// these values during an otherwise identical subscription refresh.
    public static func makeConnectionFingerprint(protocol proto: NodeProtocol, host: String, port: Int, parameters: [String: String]) -> String {
        let normalizedParameters = parameters.map { key, value in
            (NodeIdentity.normalizeParameterKey(key), value)
        }.sorted { lhs, rhs in
            if lhs.0 == rhs.0 { return lhs.1 < rhs.1 }
            return lhs.0 < rhs.0
        }
        let fields = normalizedParameters.map { pair in
            pair.0 + "=" + pair.1
        }.joined(separator: "&")
        let normalizedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
        let material = "\(proto.rawValue)|\(normalizedHost)|\(port)|\(fields)"
        return SHA256.hash(data: Data(material.utf8)).map { String(format: "%02x", $0) }.joined()
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

public enum RoutingMatcher: Codable, Hashable, Sendable { case application(String), processPath(String), userID(UInt32), domainExact(String), domainSuffix(String), domainWildcard(String), ipCIDR(String), transport(String), port(Int), portRange(ClosedRange<Int>) }
public enum RoutingAction: Codable, Hashable, Sendable { case direct, reject, proxyGroup(ProxyGroupID) }
public enum UnavailableNodeFallback: String, Codable, Sendable { case direct, reject }
public struct RoutingRule: Codable, Hashable, Identifiable, Sendable { public let id: RoutingRuleID; public var enabled: Bool; public var priority: Int; public var matchers: [RoutingMatcher]; public var action: RoutingAction; public var unavailableFallback: UnavailableNodeFallback; public var workspaceScope: WorkspaceID?; public init(id: RoutingRuleID = RoutingRuleID(), enabled: Bool = true, priority: Int, matchers: [RoutingMatcher] = [], action: RoutingAction, unavailableFallback: UnavailableNodeFallback = .direct, workspaceScope: WorkspaceID? = nil) { self.id=id; self.enabled=enabled; self.priority=priority; self.matchers=matchers; self.action=action; self.unavailableFallback=unavailableFallback; self.workspaceScope=workspaceScope } }
public struct RuleSet: Codable, Hashable, Identifiable, Sendable { public let id: RuleSetID; public var name: String; public var sourceURL: URL?; public var rules: [String]; public var defaultAction: RoutingAction; public var revision: Int; public init(id: RuleSetID = RuleSetID(), name: String, sourceURL: URL? = nil, rules: [String] = [], defaultAction: RoutingAction = .direct, revision: Int = 0) { self.id=id; self.name=name; self.sourceURL=sourceURL; self.rules=rules; self.defaultAction=defaultAction; self.revision=max(0,revision) } }

public enum DNSMode: String, Codable, CaseIterable, Sendable { case system, fakeIP, redirHost }
public struct DNSPolicy: Codable, Hashable, Identifiable, Sendable { public let id: DNSPolicyID; public var name: String; public var mode: DNSMode; public var nameservers: [String]; public var fallbackNameservers: [String]; public var proxyServer: String?; public var rules: [String]; public var takeoverEnabled: Bool; public init(id: DNSPolicyID = DNSPolicyID(), name: String, mode: DNSMode = .system, nameservers: [String] = [], fallbackNameservers: [String] = [], proxyServer: String? = nil, rules: [String] = [], takeoverEnabled: Bool = false) { self.id=id; self.name=name; self.mode=mode; self.nameservers=nameservers; self.fallbackNameservers=fallbackNameservers; self.proxyServer=proxyServer; self.rules=rules; self.takeoverEnabled=takeoverEnabled } }

public enum EntranceKind: String, Codable, CaseIterable, Sendable { case http, socks5, appRouting, tun }
public struct Entrance: Codable, Hashable, Identifiable, Sendable { public let id: EntranceID; public var kind: EntranceKind; public var enabled: Bool; public var bindAddress: String; public var port: Int?; public var defaultAction: RoutingAction; public var workspaceOverride: WorkspaceID?; public init(id: EntranceID = EntranceID(), kind: EntranceKind, enabled: Bool = false, bindAddress: String = "127.0.0.1", port: Int? = nil, defaultAction: RoutingAction = .direct, workspaceOverride: WorkspaceID? = nil) { self.id=id; self.kind=kind; self.enabled=enabled; self.bindAddress=bindAddress; self.port=port; self.defaultAction=defaultAction; self.workspaceOverride=workspaceOverride } }

public struct Workspace: Codable, Hashable, Identifiable, Sendable { public let id: WorkspaceID; public var name: String; public var nodeIDs: [NodeID]; public var proxyGroupIDs: [ProxyGroupID]; public var ruleIDs: [RoutingRuleID]; public var ruleSetIDs: [RuleSetID]; public var dnsPolicyID: DNSPolicyID; public var entranceIDs: [EntranceID]; public var revision: Int; public init(id: WorkspaceID = WorkspaceID(), name: String, nodeIDs: [NodeID] = [], proxyGroupIDs: [ProxyGroupID] = [], ruleIDs: [RoutingRuleID] = [], ruleSetIDs: [RuleSetID] = [], dnsPolicyID: DNSPolicyID, entranceIDs: [EntranceID] = [], revision: Int = 0) { self.id=id; self.name=name; self.nodeIDs=nodeIDs; self.proxyGroupIDs=proxyGroupIDs; self.ruleIDs=ruleIDs; self.ruleSetIDs=ruleSetIDs; self.dnsPolicyID=dnsPolicyID; self.entranceIDs=entranceIDs; self.revision=max(0,revision) } }

public struct RuntimeSnapshot: Codable, Hashable, Identifiable, Sendable { public let id: RuntimeSnapshotID; public let workspaceID: WorkspaceID; public let workspaceRevision: Int; public let compilerVersion: String; public let mihomoConfigHash: String; public let generatedAt: Date; public let entranceIDs: [EntranceID]; public let previousSnapshotID: RuntimeSnapshotID?; public var applicationSucceeded: Bool; public init(id: RuntimeSnapshotID = RuntimeSnapshotID(), workspaceID: WorkspaceID, workspaceRevision: Int, compilerVersion: String, mihomoConfigHash: String, generatedAt: Date = Date(), entranceIDs: [EntranceID] = [], previousSnapshotID: RuntimeSnapshotID? = nil, applicationSucceeded: Bool = false) { self.id=id; self.workspaceID=workspaceID; self.workspaceRevision=workspaceRevision; self.compilerVersion=compilerVersion; self.mihomoConfigHash=mihomoConfigHash; self.generatedAt=generatedAt; self.entranceIDs=entranceIDs; self.previousSnapshotID=previousSnapshotID; self.applicationSucceeded=applicationSucceeded } }

extension RuleSet {
    private enum CodingKeys: String, CodingKey {
        case id, name, sourceURL, rules, defaultAction, revision
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decode(RuleSetID.self, forKey: .id),
            name: try container.decode(String.self, forKey: .name),
            sourceURL: try container.decodeIfPresent(URL.self, forKey: .sourceURL),
            rules: try container.decodeIfPresent([String].self, forKey: .rules) ?? [],
            defaultAction: try container.decodeIfPresent(RoutingAction.self, forKey: .defaultAction) ?? .direct,
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
        try container.encode(revision, forKey: .revision)
    }
}
