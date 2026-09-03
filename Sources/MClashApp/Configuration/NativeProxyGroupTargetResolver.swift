import Foundation
import MClashNetworkShared

/// Resolves a policy group to the node that the native data plane may use.
///
/// Group membership is policy, while `OutboundNodeTarget` is connection
/// material. Keeping this resolver between the two makes refreshes safe: a
/// missing or unavailable pinned node is never silently replaced by a node
/// with a similar display name, and selector-backed members are recalculated
/// from the current catalog on every build.
public struct NativeProxyGroupTargetResolution: Equatable, Sendable {
    public let groupID: ProxyGroupID
    public let nodeID: NodeID?
    public let target: OutboundNodeTarget?
    public let reason: String?

    public init(groupID: ProxyGroupID, nodeID: NodeID?, target: OutboundNodeTarget?, reason: String? = nil) {
        self.groupID = groupID
        self.nodeID = nodeID
        self.target = target
        self.reason = reason
    }
}

public enum NativeProxyGroupTargetResolver {
    /// Resolve a group using only enabled, currently usable nodes. Explicit
    /// member order is retained; selector matches follow in deterministic
    /// selector/node order. Nested groups are traversed depth-first and cycles
    /// fail closed instead of recursing forever.
    public static func resolve(
        groupID: ProxyGroupID,
        groups: [ProxyGroup],
        nodes: [Node]
    ) -> NativeProxyGroupTargetResolution {
        let groupsByID = Dictionary(groups.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let nodesByID = Dictionary(nodes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let usableNodes = nodes.filter(isUsable)
        let usableIDs = Set(usableNodes.map(\.id))
        var visited = Set<ProxyGroupID>()

        guard let group = groupsByID[groupID], group.enabled else {
            return .init(groupID: groupID, nodeID: nil, target: nil, reason: "Proxy group is missing or disabled.")
        }

        func candidates(for group: ProxyGroup) -> [NodeID] {
            guard visited.insert(group.id).inserted else { return [] }
            defer { visited.remove(group.id) }

            var ids: [NodeID] = []
            var seen = Set<NodeID>()
            func append(_ id: NodeID) {
                guard usableIDs.contains(id), seen.insert(id).inserted else { return }
                ids.append(id)
            }
            for member in group.members {
                switch member {
                case let .node(id): append(id)
                case let .group(childID):
                    guard let child = groupsByID[childID], child.enabled else { continue }
                    for id in candidates(for: child) { append(id) }
                }
            }

            // Selector resolution is intentionally evaluated after durable
            // members. `fixedNodeIDs` therefore remain deterministic pins,
            // while ordinary matches track subscription refreshes.
            if !group.memberSelectors.isEmpty {
                let resolution = NodeSelectorResolver.resolve(selectors: group.memberSelectors, nodes: usableNodes)
                for id in resolution.nodeIDs { append(id) }
            }
            return ids
        }

        var ids = candidates(for: group)
        guard !ids.isEmpty else {
            return .init(groupID: groupID, nodeID: nil, target: nil, reason: "Proxy group has no usable node members.")
        }

        // URL-test groups select the best known healthy endpoint. Unknown
        // latency remains usable, but always ranks after measured latency;
        // ties use the persisted membership order and then stable ID.
        if group.type == .urlTest {
            let positions = Dictionary(uniqueKeysWithValues: ids.enumerated().map { ($1, $0) })
            ids.sort {
                let left = nodesByID[$0]!
                let right = nodesByID[$1]!
                switch (left.health.latencyMilliseconds, right.health.latencyMilliseconds) {
                case let (a?, b?):
                    if a != b { return a < b }
                case (_?, nil): return true
                case (nil, _?): return false
                default: break
                }
                let leftPosition = positions[$0] ?? 0
                let rightPosition = positions[$1] ?? 0
                if leftPosition != rightPosition { return leftPosition < rightPosition }
                return $0.rawValue.uuidString < $1.rawValue.uuidString
            }
        }

        guard let nodeID = ids.first, let node = nodesByID[nodeID], let target = node.outboundTarget else {
            return .init(groupID: groupID, nodeID: nil, target: nil, reason: "Selected node has no valid native outbound target.")
        }
        return .init(groupID: groupID, nodeID: nodeID, target: target)
    }

    private static func isUsable(_ node: Node) -> Bool {
        guard node.enabled,
              node.health.availability != .sourceRemoved,
              node.health.availability != .unsupported,
              node.health.availability != .unavailable else { return false }
        return node.outboundTarget != nil
    }
}
