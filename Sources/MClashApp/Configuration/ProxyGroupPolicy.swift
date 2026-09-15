import Foundation

public struct GroupProbeResult: Codable, Equatable, Sendable {
    public enum Outcome: Codable, Equatable, Sendable {
        case available(latencyMilliseconds: Int)
        case failed(stage: String)
    }

    public let nodeID: NodeID
    public let connectionFingerprint: String
    public let targetURL: URL
    public let checkedAt: Date
    public let outcome: Outcome

    public init(nodeID: NodeID, connectionFingerprint: String, checkedAt: Date, outcome: Outcome,
                targetURL: URL = ProxyGroupPolicySettings.defaultTestURL) {
        self.nodeID = nodeID
        self.connectionFingerprint = connectionFingerprint
        self.targetURL = targetURL
        self.checkedAt = checkedAt
        self.outcome = outcome
    }
}

public struct GroupSelectionState: Codable, Equatable, Sendable {
    public let member: ProxyGroupMember
    public let selectedAt: Date

    public init(member: ProxyGroupMember, selectedAt: Date) {
        self.member = member
        self.selectedAt = selectedAt
    }
}

public enum ProxyGroupPolicyDestination: Equatable, Sendable {
    case node(NodeID)
    case direct
    case reject
    case balance([NodeID])
    case chain([NodeID])
    case unsupported(String)
}

public struct ProxyGroupResolution: Equatable, Sendable {
    public let destination: ProxyGroupPolicyDestination
    public var orderedCandidates: [NodeID] = []
    public var selectedMember: ProxyGroupMember?
    public let reason: String
}

public struct ProxyGroupPolicySettings: Equatable, Sendable {
    public static let defaultTestURL = URL(string: "https://www.gstatic.com/generate_204")!
    public var testURL = defaultTestURL
    public var probeInterval: TimeInterval = 300
    public var probeTimeout: TimeInterval = 5
    public var selectionCooldown: TimeInterval = 30
    public var latencyToleranceMilliseconds = 50
    public var latencyToleranceRatio = 0.20
    public var failureThreshold = 2
    public var recoveryThreshold = 2

    public init() {}
}

public enum ProxyGroupPolicy {
    public static func resolve(
        document: ConfigurationDocument,
        workspace: Workspace? = nil,
        persistedOverrides: [ProxyGroupID: ProxyGroupMember] = [:],
        probes: [GroupProbeResult] = [],
        previousSelections: [ProxyGroupID: GroupSelectionState] = [:],
        now: Date = Date(),
        settings: ProxyGroupPolicySettings = ProxyGroupPolicySettings()
    ) -> [ProxyGroupID: ProxyGroupResolution] {
        let nodeScope = Set(workspace?.nodeIDs ?? [])
        let nodes = Dictionary(document.nodes.filter {
            nodeScope.isEmpty || nodeScope.contains($0.id)
        }.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let groups = Dictionary(document.proxyGroups.filter {
            $0.enabled && (workspace?.proxyGroupIDs.contains($0.id) ?? true)
        }.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let usable = probes.filter { probe in
            guard let node = nodes[probe.nodeID], node.connectionFingerprint == probe.connectionFingerprint,
                  probe.targetURL == settings.testURL else { return false }
            let age = now.timeIntervalSince(probe.checkedAt)
            return age >= 0 && age <= settings.probeInterval * 3 + settings.probeTimeout
        }.sorted { $0.checkedAt > $1.checkedAt }
        let histories = Dictionary(grouping: usable, by: \.nodeID)
        var resolver = Resolver(nodes: nodes, groups: groups, histories: histories, overrides: persistedOverrides,
                                previous: previousSelections, now: now, settings: settings)
        for id in groups.keys.sorted(by: { $0.rawValue.uuidString < $1.rawValue.uuidString }) {
            _ = resolver.resolve(id, path: [])
        }
        return resolver.results
    }

    private struct Candidate {
        let member: ProxyGroupMember
        let destination: ProxyGroupPolicyDestination
        let healthy: Bool?
        let recovered: Bool
        let latency: Int?
        let nodes: [NodeID]
    }

    private struct Resolver {
        let nodes: [NodeID: Node]
        let groups: [ProxyGroupID: ProxyGroup]
        let histories: [NodeID: [GroupProbeResult]]
        let overrides: [ProxyGroupID: ProxyGroupMember]
        let previous: [ProxyGroupID: GroupSelectionState]
        let now: Date
        let settings: ProxyGroupPolicySettings
        var results: [ProxyGroupID: ProxyGroupResolution] = [:]

        mutating func resolve(_ id: ProxyGroupID, path: Set<ProxyGroupID>) -> ProxyGroupResolution {
            if path.contains(id) { return .init(destination: .unsupported("cycle"), reason: "cycle_detected") }
            if let result = results[id] { return result }
            guard let group = groups[id] else { return .init(destination: .reject, reason: "missing_group") }
            let result = evaluate(group, path: path.union([id]))
            results[id] = result
            return result
        }

        mutating func evaluate(_ group: ProxyGroup, path: Set<ProxyGroupID>) -> ProxyGroupResolution {
            if group.type == .direct { return .init(destination: .direct, reason: "direct") }
            if group.type == .reject { return .init(destination: .reject, reason: "reject") }
            var seen = Set<ProxyGroupMember>()
            let selected = NodeSelectorResolver.resolve(selectors: group.memberSelectors,
                nodes: nodes.values.sorted { $0.id.rawValue.uuidString < $1.id.rawValue.uuidString })
            let members = (group.members + selected.nodeIDs.map(ProxyGroupMember.node)).filter { seen.insert($0).inserted }
            var candidates: [Candidate] = []
            for member in members {
                if let candidate = candidate(member, path: path) {
                    if case .unsupported("cycle") = candidate.destination {
                        return .init(destination: candidate.destination, reason: "cycle_detected")
                    }
                    candidates.append(candidate)
                }
            }
            var seenNodes = Set<NodeID>()
            let ordered = candidates.flatMap(\.nodes).filter { seenNodes.insert($0).inserted }
            func result(_ candidate: Candidate?, _ reason: String) -> ProxyGroupResolution {
                .init(destination: candidate?.destination ?? .reject, orderedCandidates: ordered,
                      selectedMember: candidate?.member, reason: reason)
            }
            if let manual = overrides[group.id] {
                return result(candidates.first { $0.member == manual }, "manual_override")
            }
            switch group.type {
            case .select:
                return result(candidates.first, candidates.isEmpty ? "no_supported_members" : "first_member")
            case .fallback:
                let eligible = candidates.filter { $0.healthy != false }
                guard let first = eligible.first else { return result(nil, "all_members_unavailable") }
                if let old = previous[group.id], let current = eligible.first(where: { $0.member == old.member }),
                   first.member != current.member, !first.recovered {
                    return result(current, "awaiting_recovery")
                }
                return result(first, "priority")
            case .urlTest:
                let eligible = candidates.filter { $0.healthy != false }
                let measured = eligible.filter { $0.latency != nil }
                guard let best = measured.min(by: { ($0.latency ?? Int.max) < ($1.latency ?? Int.max) }) else {
                    return result(eligible.first, eligible.isEmpty ? "all_members_unavailable" : "awaiting_probe")
                }
                if let old = previous[group.id], let current = eligible.first(where: { $0.member == old.member }),
                   let currentLatency = current.latency, let bestLatency = best.latency,
                   current.member != best.member {
                    if now.timeIntervalSince(old.selectedAt) < settings.selectionCooldown {
                        return result(current, "cooldown")
                    }
                    let margin = max(settings.latencyToleranceMilliseconds,
                                     Int(Double(currentLatency) * settings.latencyToleranceRatio))
                    if currentLatency - bestLatency < margin { return result(current, "within_tolerance") }
                }
                return result(best, "lowest_latency")
            case .loadBalance:
                let pool = candidates.filter { $0.healthy != false }.flatMap(\.nodes)
                return .init(destination: pool.isEmpty ? .reject : .balance(pool), orderedCandidates: ordered, reason: "load_balance")
            case .relay:
                let chain = candidates.compactMap { value -> NodeID? in
                    if case let .node(id) = value.destination { return id }; return nil
                }
                guard chain.count == members.count, !chain.isEmpty else {
                    return .init(destination: .unsupported("relay_member"), orderedCandidates: ordered, reason: "invalid_relay")
                }
                return .init(destination: .chain(chain), orderedCandidates: ordered, reason: "relay_order")
            case .direct, .reject:
                return .init(destination: .reject, reason: "empty_group")
            }
        }

        mutating func candidate(_ member: ProxyGroupMember, path: Set<ProxyGroupID>) -> Candidate? {
            switch member {
            case let .node(id):
                guard let node = nodes[id], node.enabled, node.proto != .unknown,
                      node.health.availability != .sourceRemoved, node.health.availability != .unsupported else { return nil }
                let history = histories[id] ?? []
                let fresh = history.first.map { now.timeIntervalSince($0.checkedAt) <= settings.probeInterval + settings.probeTimeout } ?? false
                let failedCount = history.prefix { if case .failed = $0.outcome { return true }; return false }.count
                let successCount = history.prefix { if case .available = $0.outcome { return true }; return false }.count
                let failed = fresh && failedCount >= settings.failureThreshold
                let latency: Int? = if fresh, case let .available(value)? = history.first?.outcome, value > 0 { value } else { nil }
                return Candidate(member: member, destination: .node(id), healthy: failed ? false : latency.map { _ in true },
                                 recovered: fresh && successCount >= settings.recoveryThreshold, latency: latency, nodes: [id])
            case let .group(id):
                let child = resolve(id, path: path)
                switch child.destination {
                case .reject:
                    if groups[id]?.type != .reject { return nil }
                    return Candidate(member: member, destination: .reject, healthy: true, recovered: true, latency: nil, nodes: [])
                case .direct:
                    return Candidate(member: member, destination: .direct, healthy: true, recovered: true, latency: nil, nodes: [])
                case let .node(nodeID):
                    guard let leaf = candidate(.node(nodeID), path: path) else { return nil }
                    return Candidate(member: member, destination: leaf.destination, healthy: leaf.healthy,
                                     recovered: leaf.recovered, latency: leaf.latency, nodes: child.orderedCandidates)
                case .unsupported, .balance, .chain:
                    return Candidate(member: member, destination: child.destination, healthy: true, recovered: true,
                                     latency: nil, nodes: child.orderedCandidates)
                }
            }
        }
    }
}
