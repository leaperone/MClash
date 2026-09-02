import Foundation

/// The connector-neutral execution plan produced from MClash's authoritative
/// configuration.  This is the boundary between policy compilation and any
/// particular runtime (Mihomo today, native connectors tomorrow).
///
/// Imported profile YAML is intentionally absent: only the MClash-owned,
/// workspace-scoped model is represented here.  `proxyGroups` contains the
/// selector memberships resolved against the current node catalog, making the
/// plan a complete, deterministic snapshot suitable for another runtime.
public struct CompiledRuntimePlan: Codable, Equatable, Sendable {
    public let workspaceID: WorkspaceID
    public let workspaceRevision: Int
    public let nodes: [Node]
    public let proxyGroups: [ProxyGroup]
    public let rules: [RoutingRule]
    public let ruleSets: [RuleSet]
    public let dnsPolicy: DNSPolicy?
    public let entrances: [Entrance]
    public let routingMode: ConfigurationRoutingMode
    public let globalProxyGroupID: ProxyGroupID?
    public let diagnostics: [ConfigurationDiagnostic]

    public init(
        workspaceID: WorkspaceID,
        workspaceRevision: Int,
        nodes: [Node],
        proxyGroups: [ProxyGroup],
        rules: [RoutingRule],
        ruleSets: [RuleSet],
        dnsPolicy: DNSPolicy?,
        entrances: [Entrance],
        routingMode: ConfigurationRoutingMode,
        globalProxyGroupID: ProxyGroupID?,
        diagnostics: [ConfigurationDiagnostic] = []
    ) {
        self.workspaceID = workspaceID
        self.workspaceRevision = workspaceRevision
        self.nodes = nodes
        self.proxyGroups = proxyGroups
        self.rules = rules
        self.ruleSets = ruleSets
        self.dnsPolicy = dnsPolicy
        self.entrances = entrances
        self.routingMode = routingMode
        self.globalProxyGroupID = globalProxyGroupID
        self.diagnostics = diagnostics
    }

    /// Lightweight structural validation for consumers that receive a plan
    /// from disk or across a process boundary. Compiler-level diagnostics are
    /// still authoritative for semantic matcher validation.
    public func validate() throws {
        let nodeIDs = Set(nodes.map(\.id))
        let groupIDs = Set(proxyGroups.map(\.id))
        guard Set(nodes.map(\.id)).count == nodes.count else {
            throw CompiledRuntimePlanValidationError.duplicateNodeID
        }
        guard groupIDs.count == proxyGroups.count else {
            throw CompiledRuntimePlanValidationError.duplicateProxyGroupID
        }
        guard Set(rules.map(\.id)).count == rules.count else {
            throw CompiledRuntimePlanValidationError.duplicateRuleID
        }
        guard Set(ruleSets.map(\.id)).count == ruleSets.count else {
            throw CompiledRuntimePlanValidationError.duplicateRuleSetID
        }
        guard Set(entrances.map(\.id)).count == entrances.count else {
            throw CompiledRuntimePlanValidationError.duplicateEntranceID
        }
        for group in proxyGroups {
            for member in group.members {
                switch member {
                case let .node(id) where !nodeIDs.contains(id):
                    throw CompiledRuntimePlanValidationError.missingNode(id)
                case let .group(id) where !groupIDs.contains(id):
                    throw CompiledRuntimePlanValidationError.missingProxyGroup(id)
                default:
                    break
                }
            }
        }
        if let globalProxyGroupID, !groupIDs.contains(globalProxyGroupID) {
            throw CompiledRuntimePlanValidationError.missingGlobalProxyGroup(globalProxyGroupID)
        }
    }
}

public enum CompiledRuntimePlanValidationError: Error, Equatable, Sendable {
    case duplicateNodeID
    case duplicateProxyGroupID
    case duplicateRuleID
    case duplicateRuleSetID
    case duplicateEntranceID
    case missingNode(NodeID)
    case missingProxyGroup(ProxyGroupID)
    case missingGlobalProxyGroup(ProxyGroupID)
}

extension CompiledRuntimePlanValidationError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .duplicateNodeID: "Compiled runtime plan contains duplicate node IDs."
        case .duplicateProxyGroupID: "Compiled runtime plan contains duplicate proxy-group IDs."
        case .duplicateRuleID: "Compiled runtime plan contains duplicate rule IDs."
        case .duplicateRuleSetID: "Compiled runtime plan contains duplicate rule-set IDs."
        case .duplicateEntranceID: "Compiled runtime plan contains duplicate entrance IDs."
        case let .missingNode(id): "Compiled runtime plan references missing node \(id.rawValue.uuidString)."
        case let .missingProxyGroup(id): "Compiled runtime plan references missing proxy group \(id.rawValue.uuidString)."
        case let .missingGlobalProxyGroup(id): "Compiled runtime plan references missing global proxy group \(id.rawValue.uuidString)."
        }
    }
}
