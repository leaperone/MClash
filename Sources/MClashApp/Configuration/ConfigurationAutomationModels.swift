import Foundation

enum ConfigurationAutomationObjectKind: String, Codable, CaseIterable, Sendable {
    case proxyGroup, rule, ruleSet, dnsPolicy, entrance, workspace
}

private func automationUUID(_ value: String, field: String) throws -> UUID {
    guard let uuid = UUID(uuidString: value) else {
        throw ConfigurationAutomationError.invalidInput("\(field) must be a UUID")
    }
    return uuid
}

struct ConfigurationAutomationNodeSettings: Codable, Equatable, Sendable {
    let id: String
    var enabled: Bool?
    var userAliasUpdate: String?
    var removeUserAlias: Bool?
    var tagsUpdate: [String]?
    var regionUpdate: String?
    var removeRegion: Bool?

    var nodeID: NodeID {
        get throws { NodeID(rawValue: try automationUUID(id, field: "nodeSettings.id")) }
    }

    func apply(to node: Node) throws -> Node {
        guard !(removeUserAlias == true && userAliasUpdate != nil) else {
            throw ConfigurationAutomationError.invalidInput(
                "userAliasUpdate and removeUserAlias cannot be used together"
            )
        }
        guard !(removeRegion == true && regionUpdate != nil) else {
            throw ConfigurationAutomationError.invalidInput(
                "regionUpdate and removeRegion cannot be used together"
            )
        }
        var updated = node
        if let enabled { updated.enabled = enabled }
        if removeUserAlias == true {
            updated.userAlias = nil
        } else if let userAliasUpdate {
            updated.userAlias = userAliasUpdate
        }
        if let tagsUpdate { updated.tags = Set(tagsUpdate) }
        if removeRegion == true {
            updated.region = nil
        } else if let regionUpdate {
            updated.region = regionUpdate
        }
        return updated
    }
}

struct ConfigurationAutomationGroupMember: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable { case node, group }
    let kind: Kind
    let id: String

    init(_ member: ProxyGroupMember) {
        switch member {
        case let .node(id): kind = .node; self.id = id.rawValue.uuidString.lowercased()
        case let .group(id): kind = .group; self.id = id.rawValue.uuidString.lowercased()
        }
    }

    func value() throws -> ProxyGroupMember {
        let uuid = try automationUUID(id, field: "proxyGroups.members.id")
        return switch kind {
        case .node: .node(NodeID(rawValue: uuid))
        case .group: .group(ProxyGroupID(rawValue: uuid))
        }
    }
}

struct ConfigurationAutomationProxyGroup: Codable, Equatable, Sendable {
    let id: String
    var name: String
    var type: ProxyGroupType
    var membersUpdate: [ConfigurationAutomationGroupMember]?
    let memberCount: Int?
    var enabled: Bool

    init(_ group: ProxyGroup) {
        id = group.id.rawValue.uuidString.lowercased()
        name = group.name
        type = group.type
        membersUpdate = nil
        memberCount = group.members.count
        enabled = group.enabled
    }

    func applying(to existing: ProxyGroup?) throws -> ProxyGroup {
        ProxyGroup(
            id: ProxyGroupID(rawValue: try automationUUID(id, field: "proxyGroups.id")),
            name: name,
            type: type,
            members: try membersUpdate?.map { try $0.value() }
                ?? existing?.members ?? [],
            enabled: enabled
        )
    }
}

struct ConfigurationAutomationMatcher: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable {
        case application, processPath, userID, domainExact, domainSuffix
        case domainWildcard, ipCIDR, transport, port, portRange
    }
    let kind: Kind
    var value: String?
    var lowerBound: Int?
    var upperBound: Int?

    init(_ matcher: RoutingMatcher) {
        lowerBound = nil
        upperBound = nil
        switch matcher {
        case let .application(value): kind = .application; self.value = value
        case let .processPath(value): kind = .processPath; self.value = value
        case let .userID(value): kind = .userID; self.value = String(value)
        case let .domainExact(value): kind = .domainExact; self.value = value
        case let .domainSuffix(value): kind = .domainSuffix; self.value = value
        case let .domainWildcard(value): kind = .domainWildcard; self.value = value
        case let .ipCIDR(value): kind = .ipCIDR; self.value = value
        case let .transport(value): kind = .transport; self.value = value
        case let .port(value): kind = .port; self.value = String(value)
        case let .portRange(range):
            kind = .portRange
            value = nil
            lowerBound = range.lowerBound
            upperBound = range.upperBound
        }
    }

    func valueType() throws -> RoutingMatcher {
        if kind == .portRange {
            guard let lowerBound, let upperBound,
                  (1...65_535).contains(lowerBound),
                  (1...65_535).contains(upperBound),
                  lowerBound <= upperBound else {
                throw ConfigurationAutomationError.invalidInput(
                    "portRange requires 1 <= lowerBound <= upperBound <= 65535"
                )
            }
            return .portRange(lowerBound...upperBound)
        }
        guard let value else {
            throw ConfigurationAutomationError.invalidInput("\(kind.rawValue) requires value")
        }
        switch kind {
        case .application: return .application(value)
        case .processPath: return .processPath(value)
        case .userID:
            guard let parsed = UInt32(value) else {
                throw ConfigurationAutomationError.invalidInput("userID value must be UInt32")
            }
            return .userID(parsed)
        case .domainExact: return .domainExact(value)
        case .domainSuffix: return .domainSuffix(value)
        case .domainWildcard: return .domainWildcard(value)
        case .ipCIDR: return .ipCIDR(value)
        case .transport: return .transport(value)
        case .port:
            guard let parsed = Int(value), (1...65_535).contains(parsed) else {
                throw ConfigurationAutomationError.invalidInput(
                    "port value must be an integer between 1 and 65535"
                )
            }
            return .port(parsed)
        case .portRange: preconditionFailure("portRange handled above")
        }
    }
}

struct ConfigurationAutomationAction: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable { case direct, reject, proxyGroup }
    let kind: Kind
    let proxyGroupID: String?

    init(_ action: RoutingAction) {
        switch action {
        case .direct: kind = .direct; proxyGroupID = nil
        case .reject: kind = .reject; proxyGroupID = nil
        case let .proxyGroup(id):
            kind = .proxyGroup
            proxyGroupID = id.rawValue.uuidString.lowercased()
        }
    }

    func value() throws -> RoutingAction {
        switch kind {
        case .direct: return .direct
        case .reject: return .reject
        case .proxyGroup:
            guard let proxyGroupID else {
                throw ConfigurationAutomationError.invalidInput(
                    "proxyGroup action requires proxyGroupID"
                )
            }
            return .proxyGroup(ProxyGroupID(rawValue: try automationUUID(
                proxyGroupID,
                field: "action.proxyGroupID"
            )))
        }
    }
}

struct ConfigurationAutomationRule: Codable, Equatable, Sendable {
    let id: String
    var enabled: Bool
    var priority: Int
    var matchersUpdate: [ConfigurationAutomationMatcher]?
    let matcherCount: Int?
    var action: ConfigurationAutomationAction
    var unavailableFallback: UnavailableNodeFallback
    var workspaceScope: String?

    init(_ rule: RoutingRule) {
        id = rule.id.rawValue.uuidString.lowercased()
        enabled = rule.enabled
        priority = rule.priority
        matchersUpdate = nil
        matcherCount = rule.matchers.count
        action = ConfigurationAutomationAction(rule.action)
        unavailableFallback = rule.unavailableFallback
        workspaceScope = rule.workspaceScope?.rawValue.uuidString.lowercased()
    }

    func applying(to existing: RoutingRule?) throws -> RoutingRule {
        RoutingRule(
            id: RoutingRuleID(rawValue: try automationUUID(id, field: "rules.id")),
            enabled: enabled,
            priority: priority,
            matchers: try matchersUpdate?.map { try $0.valueType() }
                ?? existing?.matchers ?? [],
            action: try action.value(),
            unavailableFallback: unavailableFallback,
            workspaceScope: try workspaceScope.map {
                WorkspaceID(rawValue: try automationUUID($0, field: "rules.workspaceScope"))
            }
        )
    }
}

struct ConfigurationAutomationRuleSet: Codable, Equatable, Sendable {
    let id: String
    var name: String
    var rulesUpdate: [String]?
    let ruleCount: Int?
    var defaultAction: ConfigurationAutomationAction
    var sourceURLUpdate: String?
    var removeSourceURL: Bool?

    init(_ ruleSet: RuleSet) {
        id = ruleSet.id.rawValue.uuidString.lowercased()
        name = ruleSet.name
        rulesUpdate = nil
        ruleCount = ruleSet.rules.count
        defaultAction = ConfigurationAutomationAction(ruleSet.defaultAction)
        sourceURLUpdate = nil
        removeSourceURL = nil
    }

    func applying(to existing: RuleSet?) throws -> RuleSet {
        let sourceURL: URL?
        if removeSourceURL == true {
            guard sourceURLUpdate == nil else {
                throw ConfigurationAutomationError.invalidInput(
                    "sourceURLUpdate and removeSourceURL cannot be used together"
                )
            }
            sourceURL = nil
        } else if let sourceURLUpdate {
            guard let parsed = URL(string: sourceURLUpdate),
                  ["http", "https"].contains(parsed.scheme?.lowercased() ?? ""),
                  parsed.host?.isEmpty == false else {
                throw ConfigurationAutomationError.invalidInput(
                    "sourceURLUpdate must be an HTTP or HTTPS URL with a host"
                )
            }
            sourceURL = parsed
        } else { sourceURL = existing?.sourceURL }
        return RuleSet(
            id: RuleSetID(rawValue: try automationUUID(id, field: "ruleSets.id")),
            name: name,
            sourceURL: sourceURL,
            rules: rulesUpdate ?? existing?.rules ?? [],
            defaultAction: try defaultAction.value(),
            revision: existing?.revision ?? 0
        )
    }
}

struct ConfigurationAutomationDNSPolicy: Codable, Equatable, Sendable {
    let id: String
    var name: String
    var mode: DNSMode
    var nameserversUpdate: [String]?
    let nameserverCount: Int?
    var fallbackNameserversUpdate: [String]?
    let fallbackNameserverCount: Int?
    var proxyServerUpdate: String?
    var removeProxyServer: Bool?
    var rulesUpdate: [String]?
    let ruleCount: Int?
    var takeoverEnabled: Bool

    init(_ policy: DNSPolicy) {
        id = policy.id.rawValue.uuidString.lowercased()
        name = policy.name
        mode = policy.mode
        nameserversUpdate = nil
        nameserverCount = policy.nameservers.count
        fallbackNameserversUpdate = nil
        fallbackNameserverCount = policy.fallbackNameservers.count
        proxyServerUpdate = nil
        removeProxyServer = nil
        rulesUpdate = nil
        ruleCount = policy.rules.count
        takeoverEnabled = policy.takeoverEnabled
    }

    func applying(to existing: DNSPolicy?) throws -> DNSPolicy {
        guard !(removeProxyServer == true && proxyServerUpdate != nil) else {
            throw ConfigurationAutomationError.invalidInput(
                "proxyServerUpdate and removeProxyServer cannot be used together"
            )
        }
        return DNSPolicy(
            id: DNSPolicyID(rawValue: try automationUUID(id, field: "dnsPolicies.id")),
            name: name,
            mode: mode,
            nameservers: nameserversUpdate ?? existing?.nameservers ?? [],
            fallbackNameservers: fallbackNameserversUpdate
                ?? existing?.fallbackNameservers ?? [],
            proxyServer: removeProxyServer == true ? nil : (proxyServerUpdate ?? existing?.proxyServer),
            rules: rulesUpdate ?? existing?.rules ?? [],
            takeoverEnabled: takeoverEnabled
        )
    }
}

struct ConfigurationAutomationEntrance: Codable, Equatable, Sendable {
    let id: String
    var kind: EntranceKind
    var enabled: Bool
    var bindAddress: String
    var port: Int?
    var defaultAction: ConfigurationAutomationAction
    var workspaceOverride: String?

    init(_ entrance: Entrance) {
        id = entrance.id.rawValue.uuidString.lowercased()
        kind = entrance.kind
        enabled = entrance.enabled
        bindAddress = entrance.bindAddress
        port = entrance.port
        defaultAction = ConfigurationAutomationAction(entrance.defaultAction)
        workspaceOverride = entrance.workspaceOverride?.rawValue.uuidString.lowercased()
    }

    func value() throws -> Entrance {
        Entrance(
            id: EntranceID(rawValue: try automationUUID(id, field: "entrances.id")),
            kind: kind,
            enabled: enabled,
            bindAddress: bindAddress,
            port: port,
            defaultAction: try defaultAction.value(),
            workspaceOverride: try workspaceOverride.map {
                WorkspaceID(rawValue: try automationUUID($0, field: "entrances.workspaceOverride"))
            }
        )
    }
}

struct ConfigurationAutomationWorkspace: Codable, Equatable, Sendable {
    let id: String
    var name: String
    var nodeIDsUpdate: [String]?
    let nodeCount: Int?
    var proxyGroupIDsUpdate: [String]?
    let proxyGroupCount: Int?
    var ruleIDsUpdate: [String]?
    let ruleCount: Int?
    var ruleSetIDsUpdate: [String]?
    let ruleSetCount: Int?
    var dnsPolicyID: String
    var entranceIDsUpdate: [String]?
    let entranceCount: Int?
    let revision: Int?

    init(_ workspace: Workspace) {
        id = workspace.id.rawValue.uuidString.lowercased()
        name = workspace.name
        nodeIDsUpdate = nil
        nodeCount = workspace.nodeIDs.count
        proxyGroupIDsUpdate = nil
        proxyGroupCount = workspace.proxyGroupIDs.count
        ruleIDsUpdate = nil
        ruleCount = workspace.ruleIDs.count
        ruleSetIDsUpdate = nil
        ruleSetCount = workspace.ruleSetIDs.count
        dnsPolicyID = workspace.dnsPolicyID.rawValue.uuidString.lowercased()
        entranceIDsUpdate = nil
        entranceCount = workspace.entranceIDs.count
        revision = workspace.revision
    }

    func applying(to existing: Workspace?, revision: Int) throws -> Workspace {
        Workspace(
            id: WorkspaceID(rawValue: try automationUUID(id, field: "workspaces.id")),
            name: name,
            nodeIDs: try (nodeIDsUpdate ?? existing?.nodeIDs.map {
                $0.rawValue.uuidString.lowercased()
            } ?? []).map {
                NodeID(rawValue: try automationUUID($0, field: "workspaces.nodeIDs"))
            },
            proxyGroupIDs: try (proxyGroupIDsUpdate ?? existing?.proxyGroupIDs.map {
                $0.rawValue.uuidString.lowercased()
            } ?? []).map {
                ProxyGroupID(rawValue: try automationUUID($0, field: "workspaces.proxyGroupIDs"))
            },
            ruleIDs: try (ruleIDsUpdate ?? existing?.ruleIDs.map {
                $0.rawValue.uuidString.lowercased()
            } ?? []).map {
                RoutingRuleID(rawValue: try automationUUID($0, field: "workspaces.ruleIDs"))
            },
            ruleSetIDs: try (ruleSetIDsUpdate ?? existing?.ruleSetIDs.map {
                $0.rawValue.uuidString.lowercased()
            } ?? []).map {
                RuleSetID(rawValue: try automationUUID($0, field: "workspaces.ruleSetIDs"))
            },
            dnsPolicyID: DNSPolicyID(rawValue: try automationUUID(
                dnsPolicyID,
                field: "workspaces.dnsPolicyID"
            )),
            entranceIDs: try (entranceIDsUpdate ?? existing?.entranceIDs.map {
                $0.rawValue.uuidString.lowercased()
            } ?? []).map {
                EntranceID(rawValue: try automationUUID($0, field: "workspaces.entranceIDs"))
            },
            revision: revision
        )
    }
}

struct ConfigurationAutomationDocument: Codable, Equatable, Sendable {
    let schemaVersion: Int
    var nodeSettings: [ConfigurationAutomationNodeSettings]
    var proxyGroups: [ConfigurationAutomationProxyGroup]
    var rules: [ConfigurationAutomationRule]
    var ruleSets: [ConfigurationAutomationRuleSet]
    var dnsPolicies: [ConfigurationAutomationDNSPolicy]
    var entrances: [ConfigurationAutomationEntrance]
    var workspaces: [ConfigurationAutomationWorkspace]

    init(_ document: ConfigurationDocument) {
        schemaVersion = document.schemaVersion
        nodeSettings = []
        proxyGroups = document.proxyGroups.map(ConfigurationAutomationProxyGroup.init)
        rules = document.rules.map(ConfigurationAutomationRule.init)
        ruleSets = document.ruleSets.map(ConfigurationAutomationRuleSet.init)
        dnsPolicies = document.dnsPolicies.map(ConfigurationAutomationDNSPolicy.init)
        entrances = document.entrances.map(ConfigurationAutomationEntrance.init)
        workspaces = document.workspaces.map(ConfigurationAutomationWorkspace.init)
    }

    func applying(to base: ConfigurationDocument) throws -> ConfigurationDocument {
        guard schemaVersion == ConfigurationDocument.currentSchemaVersion else {
            throw ConfigurationAutomationError.invalidInput(
                "Unsupported configuration schema version: \(schemaVersion)"
            )
        }
        let existingGroups = Dictionary(
            base.proxyGroups.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let existingRules = Dictionary(
            base.rules.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let proposedGroups = try proxyGroups.map { wire -> ProxyGroup in
            let id = ProxyGroupID(rawValue: try automationUUID(
                wire.id,
                field: "proxyGroups.id"
            ))
            return try wire.applying(to: existingGroups[id])
        }
        let proposedRules = try rules.map { wire -> RoutingRule in
            let id = RoutingRuleID(rawValue: try automationUUID(
                wire.id,
                field: "rules.id"
            ))
            return try wire.applying(to: existingRules[id])
        }
        try requireNoDeletion(base.proxyGroups.map(\.id), proposedGroups.map(\.id), "proxyGroups")
        try requireNoDeletion(base.rules.map(\.id), proposedRules.map(\.id), "rules")

        var nodeSettingsByID: [NodeID: ConfigurationAutomationNodeSettings] = [:]
        for settings in nodeSettings {
            let id = try settings.nodeID
            guard nodeSettingsByID.updateValue(settings, forKey: id) == nil else {
                throw ConfigurationAutomationError.invalidInput(
                    "nodeSettings contains duplicate identities"
                )
            }
        }
        let existingNodeIDs = Set(base.nodes.map(\.id))
        guard Set(nodeSettingsByID.keys).isSubset(of: existingNodeIDs) else {
            throw ConfigurationAutomationError.invalidInput(
                "nodeSettings can only reference nodes supplied by profiles"
            )
        }

        let existingRuleSets = Dictionary(
            base.ruleSets.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let existingDNSPolicies = Dictionary(
            base.dnsPolicies.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let proposedRuleSets = try ruleSets.map { wire -> RuleSet in
            let id = RuleSetID(rawValue: try automationUUID(wire.id, field: "ruleSets.id"))
            return try wire.applying(to: existingRuleSets[id])
        }
        let proposedDNSPolicies = try dnsPolicies.map { wire -> DNSPolicy in
            let id = DNSPolicyID(rawValue: try automationUUID(wire.id, field: "dnsPolicies.id"))
            return try wire.applying(to: existingDNSPolicies[id])
        }
        let proposedEntrances = try entrances.map { try $0.value() }
        try requireNoDeletion(base.ruleSets.map(\.id), proposedRuleSets.map(\.id), "ruleSets")
        try requireNoDeletion(base.dnsPolicies.map(\.id), proposedDNSPolicies.map(\.id), "dnsPolicies")
        try requireNoDeletion(base.entrances.map(\.id), proposedEntrances.map(\.id), "entrances")

        let oldWorkspaceRevisions = Dictionary(
            base.workspaces.map { ($0.id, $0.revision) },
            uniquingKeysWith: { first, _ in first }
        )
        let existingWorkspaces = Dictionary(
            base.workspaces.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let proposedWorkspaces = try workspaces.map { wire -> Workspace in
            let id = WorkspaceID(rawValue: try automationUUID(wire.id, field: "workspaces.id"))
            return try wire.applying(
                to: existingWorkspaces[id],
                revision: oldWorkspaceRevisions[id] ?? 0
            )
        }
        try requireNoDeletion(base.workspaces.map(\.id), proposedWorkspaces.map(\.id), "workspaces")

        var candidate = base
        candidate.nodes = try base.nodes.map { node in
            guard let settings = nodeSettingsByID[node.id] else { return node }
            return try settings.apply(to: node)
        }
        candidate.proxyGroups = proposedGroups
        candidate.rules = proposedRules
        candidate.ruleSets = proposedRuleSets
        candidate.dnsPolicies = proposedDNSPolicies
        candidate.entrances = proposedEntrances
        candidate.workspaces = proposedWorkspaces
        if candidate != base {
            for index in candidate.workspaces.indices {
                guard let oldRevision = oldWorkspaceRevisions[candidate.workspaces[index].id]
                else { continue }
                candidate.workspaces[index].revision = oldRevision == .max
                    ? .max : oldRevision + 1
            }
        }
        return candidate
    }

    private func requireNoDeletion<ID: Hashable>(
        _ existing: [ID], _ proposed: [ID], _ field: String
    ) throws {
        guard Set(existing).isSubset(of: Set(proposed)) else {
            throw ConfigurationAutomationError.invalidInput(
                "\(field) cannot delete objects; use configuration.delete"
            )
        }
    }
}

struct ConfigurationAutomationSourceSummary: Codable, Equatable, Sendable {
    let id: String
    let kind: ConfigurationSourceKind
    let displayName: String
    let revision: Int
    let lastFetchedAt: Date?
    let lastSuccessfulParseAt: Date?
    let diagnosticCount: Int
}

struct ConfigurationAutomationNodeSummary: Codable, Equatable, Sendable {
    let id: String
    let displayName: String
    let proto: NodeProtocol
    let port: Int
    let sourceLinks: [String]
    let enabled: Bool
    let health: NodeHealthSnapshot
    let userAlias: String?
    let tags: [String]
    let region: String?
    let lastSeenAt: Date?
    let parameterKeys: [String]
    let parameterKeyCount: Int
}

struct ConfigurationAutomationPage<Item: Codable & Equatable & Sendable>: Codable, Equatable, Sendable {
    let items: [Item]
    let offset: Int
    let limit: Int
    let total: Int
    let hasMore: Bool
}

struct ConfigurationAutomationCompilation: Codable, Equatable, Sendable {
    let workspaceID: String
    let workspaceRevision: Int
    let configHash: String
    let byteCount: Int
    let captureRuleCount: Int
    let captureEnabled: Bool
    let captureDNSEnabled: Bool
}

struct ConfigurationAutomationPlan: Codable, Equatable, Sendable {
    let changed: Bool
    let valid: Bool
    let diagnostics: [ConfigurationDiagnostic]
    let compilations: [ConfigurationAutomationCompilation]
}

struct ConfigurationAutomationRuntimeSnapshot: Codable, Equatable, Sendable {
    let id: String
    let workspaceID: String
    let workspaceRevision: Int
    let compilerVersion: String
    let mihomoConfigHash: String
    let generatedAt: Date
    let entranceIDs: [String]
    let previousSnapshotID: String?
    let applicationSucceeded: Bool

    init(_ snapshot: RuntimeSnapshot) {
        id = snapshot.id.rawValue.uuidString.lowercased()
        workspaceID = snapshot.workspaceID.rawValue.uuidString.lowercased()
        workspaceRevision = snapshot.workspaceRevision
        compilerVersion = snapshot.compilerVersion
        mihomoConfigHash = snapshot.mihomoConfigHash
        generatedAt = snapshot.generatedAt
        entranceIDs = snapshot.entranceIDs.map { $0.rawValue.uuidString.lowercased() }
        previousSnapshotID = snapshot.previousSnapshotID?.rawValue.uuidString.lowercased()
        applicationSucceeded = snapshot.applicationSucceeded
    }
}

struct ConfigurationAutomationSnapshot: Codable, Equatable, Sendable {
    let configurationRevision: String
    let document: ConfigurationAutomationDocument
    let sources: ConfigurationAutomationPage<ConfigurationAutomationSourceSummary>
    let nodes: ConfigurationAutomationPage<ConfigurationAutomationNodeSummary>
    let currentWorkspaceID: String?
    let lastRuntimeSnapshot: ConfigurationAutomationRuntimeSnapshot?
    let unifiedConfigurationEnabled: Bool
    let diagnostics: [ConfigurationDiagnostic]
}

struct ConfigurationAutomationDependency: Codable, Equatable, Sendable {
    let kind: String
    let id: String
}

enum ConfigurationAutomationError: Error, LocalizedError, Sendable {
    case operationInProgress
    case invalidRevision(String)
    case revisionConflict(String)
    case invalidInput(String)
    case invalidConfiguration([ConfigurationDiagnostic])
    case dependencies([ConfigurationAutomationDependency])

    var errorDescription: String? {
        switch self {
        case .operationInProgress: "Another configuration operation is already in progress"
        case .invalidRevision: "expectedRevision must be a configuration revision UUID"
        case .revisionConflict: "The configuration changed before this operation could be applied"
        case let .invalidInput(message): message
        case .invalidConfiguration: "The proposed configuration is invalid"
        case .dependencies: "The configuration object is still referenced"
        }
    }
}
