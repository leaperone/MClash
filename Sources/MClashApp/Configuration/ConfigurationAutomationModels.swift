import Foundation

enum ConfigurationAutomationLimits {
    static let nodeSettings = 2_000
    static let proxyGroups = 256
    static let rules = 2_048
    static let ruleSets = 256
    static let dnsPolicies = 64
    static let entrances = 32
    static let workspaces = 64
    static let groupMembers = 4_096
    static let workspaceNodeIDs = 4_096
    static let selectorsPerGroup = 64
    static let selectorConditions = 32
    static let selectorFixedNodeIDs = 512
    static let selectorsPerDocument = 512
    static let selectorConditionsPerDocument = 2_048
    static let selectorFixedNodeIDsPerDocument = 4_096
    static let selectorTextBytes = 256
    static let selectorMatchOperationsPerWorkspace = 4 * 1_024 * 1_024
    static let selectorMatchOperationsPerPlan = 16 * 1_024 * 1_024
    static let ruleMatchers = 256
    static let ruleSetRules = 8_192
    static let dnsNameservers = 64
    static let dnsRules = 512
    static let tags = 64
    static let tagBytes = 128
    static let aliasBytes = 256
    static let regionBytes = 128
    static let nameBytes = 256
    static let matcherValueBytes = 1_024
    static let ruleTextBytes = 2_048
    static let dnsTextBytes = 1_024
    static let bindAddressBytes = 255
    static let sourceURLBytes = 2_048
    static let compiledYAMLBytes = 4 * 1_024 * 1_024
    static let returnedDiagnostics = 256
    static let returnedDiagnosticBytes = 256 * 1_024
    static let returnedNodeSourceLinks = 256
    static let responseHeadroomBytes = 16 * 1_024
    static let snapshotPageHeadroomBytes = 128 * 1_024
    static let matcherExpansionPerRule = 4_096
    static let matcherExpansionPerWorkspace = 16_384
    static let matcherExpansionPerPlan = 65_536
    static let dnsExpansionPerWorkspace = 4_096
    static let dnsExpansionPerPlan = 16_384
    static let groupDepth = 64
}

private func requireAutomationCount(_ count: Int, maximum: Int, field: String) throws {
    guard count <= maximum else {
        throw ConfigurationAutomationError.invalidInput(
            "\(field) cannot contain more than \(maximum) items"
        )
    }
}

private func requireAutomationText(
    _ value: String,
    maximumBytes: Int,
    field: String,
    nonempty: Bool = false
) throws {
    guard (!nonempty || !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty),
          !value.unicodeScalars.contains(where: {
              CharacterSet.controlCharacters.contains($0)
                  || CharacterSet.newlines.contains($0)
          }),
          value.utf8.count <= maximumBytes else {
        throw ConfigurationAutomationError.invalidInput(
            "\(field) must \(nonempty ? "be non-empty, " : "")contain no control characters, and be at most \(maximumBytes) UTF-8 bytes"
        )
    }
}

func configurationAutomationTagsAreValid<T: Collection>(_ tags: T) -> Bool
where T.Element == String {
    tags.count <= ConfigurationAutomationLimits.tags
        && tags.allSatisfy {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && $0.utf8.count <= ConfigurationAutomationLimits.tagBytes
        }
}

func configurationAutomationProjectedTags<T: Collection>(_ tags: T) -> [String]?
where T.Element == String {
    guard configurationAutomationTagsAreValid(tags) else { return nil }
    let sorted = tags.sorted()
    guard sorted.allSatisfy({ redactedDiagnosticText($0) == $0 }) else { return nil }
    return sorted
}

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
        if let userAliasUpdate {
            try requireAutomationText(
                userAliasUpdate,
                maximumBytes: ConfigurationAutomationLimits.aliasBytes,
                field: "nodeSettings.userAliasUpdate"
            )
        }
        if let tagsUpdate {
            try requireAutomationCount(
                tagsUpdate.count,
                maximum: ConfigurationAutomationLimits.tags,
                field: "nodeSettings.tagsUpdate"
            )
            for tag in tagsUpdate {
                try requireAutomationText(
                    tag,
                    maximumBytes: ConfigurationAutomationLimits.tagBytes,
                    field: "nodeSettings.tagsUpdate",
                    nonempty: true
                )
            }
            if !tagsUpdate.isEmpty, configurationAutomationProjectedTags(node.tags) == nil {
                throw ConfigurationAutomationError.invalidInput(
                    "nodeSettings.tagsUpdate must clear legacy or redacted tags before replacing them"
                )
            }
        }
        if let regionUpdate {
            try requireAutomationText(
                regionUpdate,
                maximumBytes: ConfigurationAutomationLimits.regionBytes,
                field: "nodeSettings.regionUpdate"
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

struct ConfigurationAutomationSelectorCondition: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable {
        case nameContains, nameEquals, hostContains, hostEquals, ipEquals
        case source, protocolIs, tagContains
    }

    let kind: Kind
    let value: String

    init(_ condition: NodeSelectorCondition) {
        switch condition {
        case let .nameContains(value): kind = .nameContains; self.value = value
        case let .nameEquals(value): kind = .nameEquals; self.value = value
        case let .hostContains(value): kind = .hostContains; self.value = value
        case let .hostEquals(value): kind = .hostEquals; self.value = value
        case let .ipEquals(value): kind = .ipEquals; self.value = value
        case let .source(value):
            kind = .source
            self.value = value.rawValue.uuidString.lowercased()
        case let .protocolIs(value): kind = .protocolIs; self.value = value.rawValue
        case let .tagContains(value): kind = .tagContains; self.value = value
        }
    }

    func valueType() throws -> NodeSelectorCondition {
        try requireAutomationText(
            value,
            maximumBytes: ConfigurationAutomationLimits.selectorTextBytes,
            field: "proxyGroups.memberSelectors.conditions.value",
            nonempty: true
        )
        switch kind {
        case .nameContains: return .nameContains(value)
        case .nameEquals: return .nameEquals(value)
        case .hostContains: return .hostContains(value)
        case .hostEquals: return .hostEquals(value)
        case .ipEquals: return .ipEquals(value)
        case .source:
            return .source(SourceID(rawValue: try automationUUID(
                value,
                field: "proxyGroups.memberSelectors.conditions.value"
            )))
        case .protocolIs:
            guard let proto = NodeProtocol(rawValue: value) else {
                throw ConfigurationAutomationError.invalidInput(
                    "proxyGroups.memberSelectors protocolIs value is invalid"
                )
            }
            return .protocolIs(proto)
        case .tagContains: return .tagContains(value)
        }
    }
}

struct ConfigurationAutomationNodeSelector: Codable, Equatable, Sendable {
    let id: String
    var name: String
    var include: [ConfigurationAutomationSelectorCondition]
    var exclude: [ConfigurationAutomationSelectorCondition]
    var fixedNodeIDs: [String]

    init(_ selector: NodeSelector) {
        id = selector.id.uuidString.lowercased()
        name = selector.name
        include = selector.include.map(ConfigurationAutomationSelectorCondition.init)
        exclude = selector.exclude.map(ConfigurationAutomationSelectorCondition.init)
        fixedNodeIDs = selector.fixedNodeIDs.map { $0.rawValue.uuidString.lowercased() }
    }

    func value() throws -> NodeSelector {
        let (conditionCount, overflow) = include.count.addingReportingOverflow(exclude.count)
        guard !overflow else {
            throw ConfigurationAutomationError.invalidInput(
                "proxyGroups.memberSelectors conditions exceed the supported limit"
            )
        }
        try requireAutomationCount(
            conditionCount,
            maximum: ConfigurationAutomationLimits.selectorConditions,
            field: "proxyGroups.memberSelectors conditions"
        )
        try requireAutomationCount(
            fixedNodeIDs.count,
            maximum: ConfigurationAutomationLimits.selectorFixedNodeIDs,
            field: "proxyGroups.memberSelectors.fixedNodeIDs"
        )
        try requireAutomationText(
            name,
            maximumBytes: ConfigurationAutomationLimits.selectorTextBytes,
            field: "proxyGroups.memberSelectors.name",
            nonempty: true
        )
        return NodeSelector(
            id: try automationUUID(id, field: "proxyGroups.memberSelectors.id"),
            name: name,
            include: try include.map { try $0.valueType() },
            exclude: try exclude.map { try $0.valueType() },
            fixedNodeIDs: try fixedNodeIDs.map {
                NodeID(rawValue: try automationUUID(
                    $0,
                    field: "proxyGroups.memberSelectors.fixedNodeIDs"
                ))
            }
        )
    }
}

struct ConfigurationAutomationProxyGroup: Codable, Equatable, Sendable {
    let id: String
    var name: String
    var type: ProxyGroupType
    var membersUpdate: [ConfigurationAutomationGroupMember]?
    let memberCount: Int?
    var memberSelectors: [ConfigurationAutomationNodeSelector]?
    let selectorCount: Int?
    var enabled: Bool

    init(_ group: ProxyGroup) {
        id = group.id.rawValue.uuidString.lowercased()
        name = group.name
        type = group.type
        membersUpdate = nil
        memberCount = group.members.count
        memberSelectors = nil
        selectorCount = group.memberSelectors.count
        enabled = group.enabled
    }

    func applying(to existing: ProxyGroup?) throws -> ProxyGroup {
        try requireAutomationText(
            name,
            maximumBytes: ConfigurationAutomationLimits.nameBytes,
            field: "proxyGroups.name",
            nonempty: true
        )
        try requireAutomationCount(
            membersUpdate?.count ?? existing?.members.count ?? 0,
            maximum: ConfigurationAutomationLimits.groupMembers,
            field: "proxyGroups.membersUpdate"
        )
        let resolvedSelectors: [NodeSelector]
        if let memberSelectors {
            try requireAutomationCount(
                memberSelectors.count,
                maximum: ConfigurationAutomationLimits.selectorsPerGroup,
                field: "proxyGroups.memberSelectors"
            )
            resolvedSelectors = try memberSelectors.map { try $0.value() }
            guard Set(resolvedSelectors.map(\.id)).count == resolvedSelectors.count else {
                throw ConfigurationAutomationError.invalidInput(
                    "proxyGroups.memberSelectors contains duplicate identities"
                )
            }
        } else {
            resolvedSelectors = existing?.memberSelectors ?? []
        }
        return ProxyGroup(
            id: ProxyGroupID(rawValue: try automationUUID(id, field: "proxyGroups.id")),
            name: name,
            type: type,
            members: try membersUpdate?.map { try $0.value() }
                ?? existing?.members ?? [],
            memberSelectors: resolvedSelectors,
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
        try requireAutomationText(
            value,
            maximumBytes: ConfigurationAutomationLimits.matcherValueBytes,
            field: "rules.matchersUpdate.value",
            nonempty: true
        )
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
        case .transport:
            guard ["tcp", "udp"].contains(value.lowercased()) else {
                throw ConfigurationAutomationError.invalidInput(
                    "transport value must be tcp or udp"
                )
            }
            return .transport(value.lowercased())
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
        try requireAutomationCount(
            matchersUpdate?.count ?? existing?.matchers.count ?? 0,
            maximum: ConfigurationAutomationLimits.ruleMatchers,
            field: "rules.matchersUpdate"
        )
        return RoutingRule(
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
        try requireAutomationText(
            name,
            maximumBytes: ConfigurationAutomationLimits.nameBytes,
            field: "ruleSets.name",
            nonempty: true
        )
        let rules = rulesUpdate ?? existing?.rules ?? []
        try requireAutomationCount(
            rules.count,
            maximum: ConfigurationAutomationLimits.ruleSetRules,
            field: "ruleSets.rulesUpdate"
        )
        for rule in rules {
            try requireAutomationText(
                rule,
                maximumBytes: ConfigurationAutomationLimits.ruleTextBytes,
                field: "ruleSets.rulesUpdate",
                nonempty: true
            )
        }
        let sourceURL: URL?
        if removeSourceURL == true {
            guard sourceURLUpdate == nil else {
                throw ConfigurationAutomationError.invalidInput(
                    "sourceURLUpdate and removeSourceURL cannot be used together"
                )
            }
            sourceURL = nil
        } else if let sourceURLUpdate {
            try requireAutomationText(
                sourceURLUpdate,
                maximumBytes: ConfigurationAutomationLimits.sourceURLBytes,
                field: "ruleSets.sourceURLUpdate"
            )
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
            rules: rules,
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
        try requireAutomationText(
            name,
            maximumBytes: ConfigurationAutomationLimits.nameBytes,
            field: "dnsPolicies.name",
            nonempty: true
        )
        guard !(removeProxyServer == true && proxyServerUpdate != nil) else {
            throw ConfigurationAutomationError.invalidInput(
                "proxyServerUpdate and removeProxyServer cannot be used together"
            )
        }
        let nameservers = nameserversUpdate ?? existing?.nameservers ?? []
        let fallbackNameservers = fallbackNameserversUpdate
            ?? existing?.fallbackNameservers ?? []
        let rules = rulesUpdate ?? existing?.rules ?? []
        try requireAutomationCount(
            nameservers.count,
            maximum: ConfigurationAutomationLimits.dnsNameservers,
            field: "dnsPolicies.nameserversUpdate"
        )
        try requireAutomationCount(
            fallbackNameservers.count,
            maximum: ConfigurationAutomationLimits.dnsNameservers,
            field: "dnsPolicies.fallbackNameserversUpdate"
        )
        try requireAutomationCount(
            rules.count,
            maximum: ConfigurationAutomationLimits.dnsRules,
            field: "dnsPolicies.rulesUpdate"
        )
        for (field, values) in [
            ("dnsPolicies.nameserversUpdate", nameservers),
            ("dnsPolicies.fallbackNameserversUpdate", fallbackNameservers),
            ("dnsPolicies.rulesUpdate", rules),
        ] {
            for value in values {
                try requireAutomationText(
                    value,
                    maximumBytes: ConfigurationAutomationLimits.dnsTextBytes,
                    field: field,
                    nonempty: true
                )
            }
        }
        if let proxyServer = removeProxyServer == true
            ? nil : (proxyServerUpdate ?? existing?.proxyServer) {
            try requireAutomationText(
                proxyServer,
                maximumBytes: ConfigurationAutomationLimits.dnsTextBytes,
                field: "dnsPolicies.proxyServerUpdate",
                nonempty: true
            )
        }
        return DNSPolicy(
            id: DNSPolicyID(rawValue: try automationUUID(id, field: "dnsPolicies.id")),
            name: name,
            mode: mode,
            nameservers: nameservers,
            fallbackNameservers: fallbackNameservers,
            proxyServer: removeProxyServer == true ? nil : (proxyServerUpdate ?? existing?.proxyServer),
            rules: rules,
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
        try requireAutomationText(
            bindAddress,
            maximumBytes: ConfigurationAutomationLimits.bindAddressBytes,
            field: "entrances.bindAddress",
            nonempty: enabled
        )
        return Entrance(
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

enum ConfigurationAutomationNodeScope: String, Codable, Sendable {
    case allEnabled, listed
}

struct ConfigurationAutomationWorkspace: Codable, Equatable, Sendable {
    let id: String
    var name: String
    var nodeScope: ConfigurationAutomationNodeScope?
    var nodeIDsUpdate: [String]?
    let nodeCount: Int?
    let effectiveNodeCount: Int?
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

    init(_ workspace: Workspace, runtimeEligibleNodeIDs: Set<NodeID>) {
        id = workspace.id.rawValue.uuidString.lowercased()
        name = workspace.name
        nodeScope = workspace.nodeIDs.isEmpty ? .allEnabled : .listed
        nodeIDsUpdate = nil
        nodeCount = workspace.nodeIDs.count
        effectiveNodeCount = workspace.nodeIDs.isEmpty
            ? runtimeEligibleNodeIDs.count
            : Set(workspace.nodeIDs).intersection(runtimeEligibleNodeIDs).count
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
        try requireAutomationText(
            name,
            maximumBytes: ConfigurationAutomationLimits.nameBytes,
            field: "workspaces.name",
            nonempty: true
        )
        let existingScope = existing.map {
            $0.nodeIDs.isEmpty
                ? ConfigurationAutomationNodeScope.allEnabled
                : ConfigurationAutomationNodeScope.listed
        }
        guard let resolvedNodeScope = nodeScope ?? existingScope else {
            throw ConfigurationAutomationError.invalidInput(
                "workspaces.nodeScope is required for a new workspace"
            )
        }
        let nodeIDs: [String]
        switch resolvedNodeScope {
        case .allEnabled:
            guard nodeIDsUpdate?.isEmpty != false else {
                throw ConfigurationAutomationError.invalidInput(
                    "workspaces.nodeIDsUpdate must be empty when nodeScope is allEnabled"
                )
            }
            nodeIDs = []
        case .listed:
            nodeIDs = nodeIDsUpdate ?? existing?.nodeIDs.map {
                $0.rawValue.uuidString.lowercased()
            } ?? []
            guard !nodeIDs.isEmpty else {
                throw ConfigurationAutomationError.invalidInput(
                    "workspaces.nodeIDsUpdate must contain at least one ID when nodeScope is listed"
                )
            }
        }
        let proxyGroupIDs = proxyGroupIDsUpdate ?? existing?.proxyGroupIDs.map {
            $0.rawValue.uuidString.lowercased()
        } ?? []
        let ruleIDs = ruleIDsUpdate ?? existing?.ruleIDs.map {
            $0.rawValue.uuidString.lowercased()
        } ?? []
        let ruleSetIDs = ruleSetIDsUpdate ?? existing?.ruleSetIDs.map {
            $0.rawValue.uuidString.lowercased()
        } ?? []
        let entranceIDs = entranceIDsUpdate ?? existing?.entranceIDs.map {
            $0.rawValue.uuidString.lowercased()
        } ?? []
        for (values, maximum, field) in [
            (nodeIDs, ConfigurationAutomationLimits.workspaceNodeIDs, "nodeIDsUpdate"),
            (proxyGroupIDs, ConfigurationAutomationLimits.proxyGroups, "proxyGroupIDsUpdate"),
            (ruleIDs, ConfigurationAutomationLimits.rules, "ruleIDsUpdate"),
            (ruleSetIDs, ConfigurationAutomationLimits.ruleSets, "ruleSetIDsUpdate"),
            (entranceIDs, ConfigurationAutomationLimits.entrances, "entranceIDsUpdate"),
        ] {
            try requireAutomationCount(
                values.count,
                maximum: maximum,
                field: "workspaces.\(field)"
            )
        }
        return Workspace(
            id: WorkspaceID(rawValue: try automationUUID(id, field: "workspaces.id")),
            name: name,
            nodeIDs: try nodeIDs.map {
                NodeID(rawValue: try automationUUID($0, field: "workspaces.nodeIDs"))
            },
            proxyGroupIDs: try proxyGroupIDs.map {
                ProxyGroupID(rawValue: try automationUUID($0, field: "workspaces.proxyGroupIDs"))
            },
            ruleIDs: try ruleIDs.map {
                RoutingRuleID(rawValue: try automationUUID($0, field: "workspaces.ruleIDs"))
            },
            ruleSetIDs: try ruleSetIDs.map {
                RuleSetID(rawValue: try automationUUID($0, field: "workspaces.ruleSetIDs"))
            },
            dnsPolicyID: DNSPolicyID(rawValue: try automationUUID(
                dnsPolicyID,
                field: "workspaces.dnsPolicyID"
            )),
            entranceIDs: try entranceIDs.map {
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
        let runtimeEligibleNodeIDs = Set(document.nodes.compactMap { node in
            node.enabled
                && node.health.availability != .sourceRemoved
                && node.health.availability != .unsupported
                ? node.id : nil
        })
        schemaVersion = document.schemaVersion
        nodeSettings = []
        proxyGroups = document.proxyGroups.map(ConfigurationAutomationProxyGroup.init)
        rules = document.rules.map(ConfigurationAutomationRule.init)
        ruleSets = document.ruleSets.map(ConfigurationAutomationRuleSet.init)
        dnsPolicies = document.dnsPolicies.map(ConfigurationAutomationDNSPolicy.init)
        entrances = document.entrances.map(ConfigurationAutomationEntrance.init)
        workspaces = document.workspaces.map {
            ConfigurationAutomationWorkspace(
                $0,
                runtimeEligibleNodeIDs: runtimeEligibleNodeIDs
            )
        }
    }

    func applying(to base: ConfigurationDocument) throws -> ConfigurationDocument {
        guard schemaVersion == ConfigurationDocument.currentSchemaVersion else {
            throw ConfigurationAutomationError.invalidInput(
                "Unsupported configuration schema version: \(schemaVersion)"
            )
        }
        try requireAutomationCount(
            nodeSettings.count,
            maximum: ConfigurationAutomationLimits.nodeSettings,
            field: "nodeSettings"
        )
        try requireAutomationCount(
            proxyGroups.count,
            maximum: ConfigurationAutomationLimits.proxyGroups,
            field: "proxyGroups"
        )
        try requireAutomationCount(
            rules.count,
            maximum: ConfigurationAutomationLimits.rules,
            field: "rules"
        )
        try requireAutomationCount(
            ruleSets.count,
            maximum: ConfigurationAutomationLimits.ruleSets,
            field: "ruleSets"
        )
        try requireAutomationCount(
            dnsPolicies.count,
            maximum: ConfigurationAutomationLimits.dnsPolicies,
            field: "dnsPolicies"
        )
        try requireAutomationCount(
            entrances.count,
            maximum: ConfigurationAutomationLimits.entrances,
            field: "entrances"
        )
        try requireAutomationCount(
            workspaces.count,
            maximum: ConfigurationAutomationLimits.workspaces,
            field: "workspaces"
        )
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
        var selectorCount = 0
        var conditionCount = 0
        var fixedNodeIDCount = 0
        for group in proposedGroups {
            selectorCount += group.memberSelectors.count
            for selector in group.memberSelectors {
                conditionCount += selector.include.count + selector.exclude.count
                fixedNodeIDCount += selector.fixedNodeIDs.count
            }
        }
        let existingSelectorCounts = base.proxyGroups.reduce(
            into: (selectors: 0, conditions: 0, fixedNodeIDs: 0)
        ) { totals, group in
            totals.selectors += group.memberSelectors.count
            for selector in group.memberSelectors {
                totals.conditions += selector.include.count + selector.exclude.count
                totals.fixedNodeIDs += selector.fixedNodeIDs.count
            }
        }
        try requireAutomationCount(
            selectorCount,
            maximum: max(
                ConfigurationAutomationLimits.selectorsPerDocument,
                existingSelectorCounts.selectors
            ),
            field: "proxyGroups.memberSelectors"
        )
        try requireAutomationCount(
            conditionCount,
            maximum: max(
                ConfigurationAutomationLimits.selectorConditionsPerDocument,
                existingSelectorCounts.conditions
            ),
            field: "proxyGroups.memberSelectors conditions"
        )
        try requireAutomationCount(
            fixedNodeIDCount,
            maximum: max(
                ConfigurationAutomationLimits.selectorFixedNodeIDsPerDocument,
                existingSelectorCounts.fixedNodeIDs
            ),
            field: "proxyGroups.memberSelectors.fixedNodeIDs"
        )
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
    let sourceLinkCount: Int
    let enabled: Bool
    let health: NodeHealthSnapshot
    let userAlias: String?
    let tags: [String]
    let tagCount: Int
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
    let diagnosticCount: Int
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
    let diagnosticCount: Int
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
