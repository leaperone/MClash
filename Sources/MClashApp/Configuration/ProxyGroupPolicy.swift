import Foundation

/// The result of one runtime probe. A probe is usable only for the exact
/// connection fingerprint that was tested.
public struct GroupProbeResult: Equatable, Sendable {
    public enum Outcome: Equatable, Sendable {
        case available(latencyMilliseconds: Int)
        case failed(stage: String)
    }

    public let nodeID: NodeID
    public let connectionFingerprint: String
    public let checkedAt: Date
    public let outcome: Outcome

    public init(nodeID: NodeID, connectionFingerprint: String, checkedAt: Date, outcome: Outcome) {
        self.nodeID = nodeID
        self.connectionFingerprint = connectionFingerprint
        self.checkedAt = checkedAt
        self.outcome = outcome
    }
}

public struct GroupSelectionState: Equatable, Sendable {
    public let member: NodeID
    public let selectedAt: Date

    public init(member: NodeID, selectedAt: Date) {
        self.member = member
        self.selectedAt = selectedAt
    }
}

public enum ProxyGroupPolicyDestination: Equatable, Sendable {
    case node(NodeID)
    case direct
    case reject
    case unsupported(String)
}

public struct ProxyGroupResolution: Equatable, Sendable {
    public let destination: ProxyGroupPolicyDestination
    public let orderedCandidates: [NodeID]
    public let selectedMember: NodeID?
    public let reason: String

    public init(destination: ProxyGroupPolicyDestination, orderedCandidates: [NodeID] = [], selectedMember: NodeID? = nil, reason: String) {
        self.destination = destination
        self.orderedCandidates = orderedCandidates
        self.selectedMember = selectedMember
        self.reason = reason
    }
}

public struct ProxyGroupPolicySettings: Equatable, Sendable {
    public var probeInterval: TimeInterval
    public var probeTimeout: TimeInterval
    public var selectionCooldown: TimeInterval
    public var latencyToleranceMilliseconds: Int
    public var latencyToleranceRatio: Double

    public init(probeInterval: TimeInterval = 300, probeTimeout: TimeInterval = 5, selectionCooldown: TimeInterval = 30, latencyToleranceMilliseconds: Int = 50, latencyToleranceRatio: Double = 0.20) {
        self.probeInterval = max(0, probeInterval)
        self.probeTimeout = max(0.001, probeTimeout)
        self.selectionCooldown = max(0, selectionCooldown)
        self.latencyToleranceMilliseconds = max(0, latencyToleranceMilliseconds)
        self.latencyToleranceRatio = max(0, latencyToleranceRatio)
    }
}

public enum ProxyGroupPolicy {
    public static func resolve(
        document: ConfigurationDocument,
        workspace: Workspace? = nil,
        persistedOverrides: [ProxyGroupID: NodeID] = [:],
        probes: [GroupProbeResult] = [],
        previousSelections: [ProxyGroupID: GroupSelectionState] = [:],
        now: Date = Date(),
        settings: ProxyGroupPolicySettings = ProxyGroupPolicySettings()
    ) -> [ProxyGroupID: ProxyGroupResolution] {
        let workspaceNodeIDs = workspace.map { Set($0.nodeIDs) }
        let nodes = document.nodes.reduce(into: [NodeID: Node]()) { result, node in
            guard workspaceNodeIDs?.contains(node.id) ?? true else { return }
            if result[node.id] == nil { result[node.id] = node }
        }
        let groups = document.proxyGroups.reduce(into: [ProxyGroupID: ProxyGroup]()) { result, group in
            guard group.enabled, workspace?.proxyGroupIDs.contains(group.id) ?? true else { return }
            if result[group.id] == nil { result[group.id] = group }
        }
        let currentProbes = newestProbes(probes, nodes: nodes)
        var memo: [ProxyGroupID: ProxyGroupResolution] = [:]
        var visiting = Set<ProxyGroupID>()
        for id in groups.keys.sorted(by: stableIDOrder) {
            _ = resolveGroup(id, groups: groups, nodes: nodes, probes: currentProbes, overrides: persistedOverrides, previous: previousSelections, now: now, settings: settings, memo: &memo, visiting: &visiting)
        }
        return memo
    }

    private static func resolveGroup(_ id: ProxyGroupID, groups: [ProxyGroupID: ProxyGroup], nodes: [NodeID: Node], probes: [NodeID: GroupProbeResult], overrides: [ProxyGroupID: NodeID], previous: [ProxyGroupID: GroupSelectionState], now: Date, settings: ProxyGroupPolicySettings, memo: inout [ProxyGroupID: ProxyGroupResolution], visiting: inout Set<ProxyGroupID>) -> ProxyGroupResolution {
        if let result = memo[id] { return result }
        guard let group = groups[id] else { return ProxyGroupResolution(destination: .reject, reason: "missing_group") }
        guard visiting.insert(id).inserted else { return ProxyGroupResolution(destination: .unsupported("cycle"), reason: "cycle_detected") }
        defer { visiting.remove(id) }

        if group.type == .direct { let r = ProxyGroupResolution(destination: .direct, reason: "direct"); memo[id] = r; return r }
        if group.type == .reject { let r = ProxyGroupResolution(destination: .reject, reason: "reject"); memo[id] = r; return r }
        if group.type == .loadBalance { let r = ProxyGroupResolution(destination: .unsupported("load_balance"), reason: "unsupported_group_type"); memo[id] = r; return r }
        if group.type == .relay { let r = ProxyGroupResolution(destination: .unsupported("relay"), reason: "unsupported_group_type"); memo[id] = r; return r }

        var candidates: [NodeID] = []
        var seen = Set<NodeID>()
        var childError: String?
        let selectedIDs = group.members.compactMap { member -> NodeID? in
            switch member {
            case .node(let nodeID): return nodeID
            case .group(let childID):
                let child = resolveGroup(childID, groups: groups, nodes: nodes, probes: probes, overrides: overrides, previous: previous, now: now, settings: settings, memo: &memo, visiting: &visiting)
                if case .unsupported(let error) = child.destination { childError = error; return nil }
                return child.selectedMember
            }
        }
        if let childError {
            let r = ProxyGroupResolution(destination: .unsupported(childError), reason: childError == "cycle" ? "cycle_detected" : "child_unsupported")
            memo[id] = r
            return r
        }
        for nodeID in selectedIDs where nodes[nodeID] != nil && seen.insert(nodeID).inserted { candidates.append(nodeID) }
        let selectorIDs = NodeSelectorResolver.resolve(selectors: group.memberSelectors, nodes: Array(nodes.values)).nodeIDs
        for nodeID in selectorIDs where seen.insert(nodeID).inserted { candidates.append(nodeID) }
        let available = candidates.filter { nodes[$0]?.enabled == true && nodes[$0]?.proto != .unknown }
        guard !available.isEmpty else { let r = ProxyGroupResolution(destination: .reject, orderedCandidates: candidates, reason: "no_supported_members"); memo[id] = r; return r }

        if let manual = overrides[id], available.contains(manual) {
            let r = ProxyGroupResolution(destination: .node(manual), orderedCandidates: candidates, selectedMember: manual, reason: "manual_override")
            memo[id] = r; return r
        }
        let healthy = available.filter { nodeID in
            guard let probe = probes[nodeID], probe.isAvailable else { return false }
            return now.timeIntervalSince(probe.checkedAt) <= settings.probeInterval
        }
        let chosen: NodeID?
        var reason = "ordered_fallback"
        switch group.type {
        case .urlTest:
            chosen = chooseURLTest(available: available, healthy: healthy, probes: probes, previous: previous[id], now: now, settings: settings)
            reason = chosen == previous[id]?.member && chosen != nil ? "cooldown" : "url_test"
        case .fallback, .select:
            let allHaveFreshProbes = available.allSatisfy { probe in
                guard let result = probes[probe] else { return false }
                return now.timeIntervalSince(result.checkedAt) <= settings.probeInterval
            }
            chosen = healthy.first ?? (allHaveFreshProbes ? nil : available.first)
            reason = healthy.isEmpty ? (allHaveFreshProbes ? "all_probes_failed" : "fallback_without_healthy_probe") : "first_healthy"
        default:
            chosen = nil
        }
        guard let chosen else { let r = ProxyGroupResolution(destination: .reject, orderedCandidates: candidates, reason: "unsupported_selection"); memo[id] = r; return r }
        let r = ProxyGroupResolution(destination: .node(chosen), orderedCandidates: candidates, selectedMember: chosen, reason: reason)
        memo[id] = r
        return r
    }

    private static func chooseURLTest(available: [NodeID], healthy: [NodeID], probes: [NodeID: GroupProbeResult], previous: GroupSelectionState?, now: Date, settings: ProxyGroupPolicySettings) -> NodeID? {
        guard !healthy.isEmpty else { return available.first }
        let ranked = healthy.sorted { lhs, rhs in
            let l = probes[lhs]!.latency
            let r = probes[rhs]!.latency
            return l == r ? stableIDOrder(lhs, rhs) : l < r
        }
        guard let best = ranked.first else { return nil }
        if let previous, available.contains(previous.member), now.timeIntervalSince(previous.selectedAt) < settings.selectionCooldown, let old = probes[previous.member]?.latency {
            let threshold = max(settings.latencyToleranceMilliseconds, Int(Double(old) * settings.latencyToleranceRatio))
            if probes[best]!.latency >= old - threshold { return previous.member }
        }
        return best
    }

    private static func newestProbes(_ values: [GroupProbeResult], nodes: [NodeID: Node]) -> [NodeID: GroupProbeResult] {
        var result: [NodeID: GroupProbeResult] = [:]
        for probe in values where nodes[probe.nodeID]?.connectionFingerprint == probe.connectionFingerprint {
            if result[probe.nodeID] == nil || result[probe.nodeID]!.checkedAt < probe.checkedAt { result[probe.nodeID] = probe }
        }
        return result
    }

    private static func stableIDOrder(_ lhs: NodeID, _ rhs: NodeID) -> Bool { lhs.rawValue.uuidString < rhs.rawValue.uuidString }
}

private extension GroupProbeResult.Outcome {
    var isAvailable: Bool { if case .available = self { return true }; return false }
    var latency: Int { if case .available(let value) = self { return max(1, value) }; return Int.max }
}

private extension GroupProbeResult {
    var isAvailable: Bool { outcome.isAvailable }
    var latency: Int { outcome.latency }
}
