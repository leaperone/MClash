import Foundation

struct ProxyTopologyBuilder: Sendable {
    func build(
        collection: MihomoProxyCollection,
        profileStructure: ProfileStructure = .empty
    ) -> ProxyTopology {
        let runtimeProxies = collection.proxies
        let runtimeGroups = runtimeProxies.values.filter(isGroup)
        let runtimeGroupNames = Set(runtimeGroups.map(\.name))

        let configuredGroups = profileStructure.groupOrder.filter { runtimeGroupNames.contains($0) }
        let configuredGroupSet = Set(configuredGroups)
        let fallbackGroups = runtimeGroups
            .filter { !configuredGroupSet.contains($0.name) }
            .sorted(by: stableProxyOrder)
            .map(\.name)
        let groupOrder = configuredGroups + fallbackGroups

        var vertices = Dictionary(uniqueKeysWithValues: runtimeProxies.values.map { proxy in
            let groupKind = ProxyGroupKind(rawType: proxy.type)
            let kind: ProxyTopologyVertexKind = isGroup(proxy)
                ? .group(groupKind)
                : .endpoint
            return (
                proxy.name,
                ProxyTopologyVertex(
                    id: proxy.name,
                    name: proxy.name,
                    type: proxy.type,
                    kind: kind,
                    children: proxy.all,
                    now: nonEmpty(proxy.now),
                    fixed: nonEmpty(proxy.fixed),
                    dialerProxy: nonEmpty(proxy.dialerProxy),
                    providerName: nonEmpty(proxy.providerName),
                    hidden: proxy.hidden,
                    alive: proxy.alive
                )
            )
        })

        var edges: [ProxyTopologyEdge] = []
        var edgeSet = Set<ProxyTopologyEdge>()
        var unresolved = Set<String>()
        var childrenByGroup: [String: [String]] = [:]

        func appendEdge(_ edge: ProxyTopologyEdge) {
            if edgeSet.insert(edge).inserted {
                edges.append(edge)
            }
            if vertices[edge.target] == nil {
                unresolved.insert(edge.target)
                vertices[edge.target] = ProxyTopologyVertex(
                    id: edge.target,
                    name: edge.target,
                    type: "Unresolved",
                    kind: .unresolved,
                    children: [],
                    now: nil,
                    fixed: nil,
                    dialerProxy: nil,
                    providerName: nil,
                    hidden: false,
                    alive: false
                )
            }
        }

        for groupName in groupOrder {
            guard let vertex = vertices[groupName] else { continue }
            childrenByGroup[groupName] = vertex.children
            for child in vertex.children {
                appendEdge(ProxyTopologyEdge(source: groupName, target: child, kind: .member))
            }
        }

        let nonGroupVertices = runtimeProxies.values
            .filter { !runtimeGroupNames.contains($0.name) }
            .sorted(by: stableProxyOrder)
        for proxy in runtimeGroups.sorted(by: stableProxyOrder) + nonGroupVertices {
            if let dialerProxy = nonEmpty(proxy.dialerProxy) {
                appendEdge(ProxyTopologyEdge(source: proxy.name, target: dialerProxy, kind: .dialer))
            }
        }

        let vertexRank = stableVertexRanks(groupOrder: groupOrder, vertices: vertices)
        edges.sort { lhs, rhs in
            let leftRank = vertexRank[lhs.source] ?? Int.max
            let rightRank = vertexRank[rhs.source] ?? Int.max
            if leftRank != rightRank { return leftRank < rightRank }
            if lhs.kind != rhs.kind { return lhs.kind.rawValue < rhs.kind.rawValue }
            return stableNameThenRaw(lhs.target, rhs.target)
        }

        var parentsByChild: [String: [String]] = [:]
        for edge in edges {
            if parentsByChild[edge.target, default: []].contains(edge.source) == false {
                parentsByChild[edge.target, default: []].append(edge.source)
            }
        }
        for child in parentsByChild.keys {
            parentsByChild[child]?.sort { lhs, rhs in
                let leftRank = vertexRank[lhs] ?? Int.max
                let rightRank = vertexRank[rhs] ?? Int.max
                if leftRank != rightRank { return leftRank < rightRank }
                return stableNameThenRaw(lhs, rhs)
            }
        }

        let roots = groupOrder.filter { parentsByChild[$0, default: []].isEmpty }
        let visibleGroupOrder = groupOrder.filter { vertices[$0]?.hidden != true }
        let cycles = detectCycles(vertices: vertices, edges: edges, rank: vertexRank)

        return ProxyTopology(
            vertices: vertices,
            edges: edges,
            groupOrder: groupOrder,
            visibleGroupOrder: visibleGroupOrder,
            childrenByGroup: childrenByGroup,
            parentsByChild: parentsByChild,
            roots: roots,
            unresolved: unresolved,
            cycles: cycles
        )
    }

    private func isGroup(_ proxy: MihomoProxy) -> Bool {
        !proxy.all.isEmpty || ProxyGroupKind(rawType: proxy.type).isKnownGroup
    }

    private func stableProxyOrder(_ lhs: MihomoProxy, _ rhs: MihomoProxy) -> Bool {
        if lhs.name != rhs.name { return stableNameThenRaw(lhs.name, rhs.name) }
        if lhs.type != rhs.type { return stableNameThenRaw(lhs.type, rhs.type) }
        return (lhs.id ?? "") < (rhs.id ?? "")
    }

    private func stableVertexRanks(
        groupOrder: [String],
        vertices: [String: ProxyTopologyVertex]
    ) -> [String: Int] {
        var ordered = groupOrder
        let existing = Set(groupOrder)
        ordered.append(contentsOf: vertices.keys.filter { !existing.contains($0) }.sorted(by: stableNameThenRaw))
        return Dictionary(uniqueKeysWithValues: ordered.enumerated().map { ($0.element, $0.offset) })
    }

    private func detectCycles(
        vertices: [String: ProxyTopologyVertex],
        edges: [ProxyTopologyEdge],
        rank: [String: Int]
    ) -> [ProxyTopologyCycle] {
        let adjacency = Dictionary(grouping: edges, by: \.source).mapValues { sourceEdges in
            sourceEdges.sorted { lhs, rhs in
                let leftRank = rank[lhs.target] ?? Int.max
                let rightRank = rank[rhs.target] ?? Int.max
                if leftRank != rightRank { return leftRank < rightRank }
                if lhs.kind != rhs.kind { return lhs.kind.rawValue < rhs.kind.rawValue }
                return stableNameThenRaw(lhs.target, rhs.target)
            }
        }
        let orderedVertices = vertices.keys.sorted { lhs, rhs in
            let leftRank = rank[lhs] ?? Int.max
            let rightRank = rank[rhs] ?? Int.max
            if leftRank != rightRank { return leftRank < rightRank }
            return stableNameThenRaw(lhs, rhs)
        }

        var state: [String: VisitState] = [:]
        var stack: [String] = []
        var stackIndexes: [String: Int] = [:]
        var cyclesByKey: [String: ProxyTopologyCycle] = [:]

        func visit(_ vertex: String) {
            state[vertex] = .visiting
            stackIndexes[vertex] = stack.count
            stack.append(vertex)

            for edge in adjacency[vertex, default: []] {
                switch state[edge.target, default: .unvisited] {
                case .unvisited:
                    visit(edge.target)
                case .visiting:
                    guard let start = stackIndexes[edge.target] else { continue }
                    let core = Array(stack[start...])
                    let canonical = canonicalCycle(core)
                    cyclesByKey[canonical.key] = ProxyTopologyCycle(nodes: canonical.nodes)
                case .visited:
                    break
                }
            }

            _ = stack.popLast()
            stackIndexes[vertex] = nil
            state[vertex] = .visited
        }

        for vertex in orderedVertices where state[vertex, default: .unvisited] == .unvisited {
            visit(vertex)
        }

        return cyclesByKey.keys.sorted().compactMap { cyclesByKey[$0] }
    }
}

private enum VisitState {
    case unvisited
    case visiting
    case visited
}

private func stableNameThenRaw(_ lhs: String, _ rhs: String) -> Bool {
    proxyStableNameComesBefore(lhs, rhs)
}

private func nonEmpty(_ value: String?) -> String? {
    guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
        return nil
    }
    return value
}

private func canonicalCycle(_ core: [String]) -> (key: String, nodes: [String]) {
    guard !core.isEmpty else { return ("", []) }
    let rotations = core.indices.map { index -> [String] in
        Array(core[index...]) + Array(core[..<index])
    }
    let best = rotations.min { lhs, rhs in
        lhs.joined(separator: "\u{0}") < rhs.joined(separator: "\u{0}")
    } ?? core
    return (best.joined(separator: "\u{0}"), best + [best[0]])
}
