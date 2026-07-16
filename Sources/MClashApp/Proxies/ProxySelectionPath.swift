import Foundation

enum ProxySelectionDecision: Equatable, Hashable, Sendable {
    case selector
    case urlTest
    case fallback
    case fixedOverride
    case relay
    case automatic(String)
}

enum ProxySelectionHopKind: Equatable, Hashable, Sendable {
    case selection(ProxySelectionDecision)
    case dialer
    case dialerSelection(ProxySelectionDecision)
}

struct ProxySelectionHop: Equatable, Hashable, Sendable {
    let source: String
    let target: String
    let kind: ProxySelectionHopKind
}

enum ProxySelectionCertainty: Int, Equatable, Comparable, Sendable {
    case deterministic
    case automatic
    case perConnection

    static func < (lhs: ProxySelectionCertainty, rhs: ProxySelectionCertainty) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

enum ProxySelectionPathIssue: Equatable, Sendable {
    case rootNotFound(String)
    case unresolvedReference(String)
    case noSelection(String)
    case cycle([String])
    case loadBalance(group: String, candidates: [String])
    case dialerUnresolvedReference(String)
    case dialerNoSelection(String)
    case dialerCycle([String])
    case dialerLoadBalance(group: String, candidates: [String])
    case dialerDepthLimit
}

struct ProxySelectionPath: Equatable, Sendable {
    let root: String
    let hops: [ProxySelectionHop]
    let terminal: String?
    let certainty: ProxySelectionCertainty
    let issue: ProxySelectionPathIssue?

    var selectionHops: [ProxySelectionHop] {
        hops.filter { hop in
            if case .selection = hop.kind { return true }
            return false
        }
    }

    var dialerHops: [ProxySelectionHop] {
        hops.filter { hop in
            switch hop.kind {
            case .dialer, .dialerSelection: return true
            case .selection: return false
            }
        }
    }

    var route: [String] {
        [root] + selectionHops.map(\.target)
    }
}

struct ProxySelectionPathResolver: Sendable {
    func resolve(from root: String, topology: ProxyTopology) -> ProxySelectionPath {
        guard topology.vertices[root] != nil else {
            return ProxySelectionPath(
                root: root,
                hops: [],
                terminal: nil,
                certainty: .deterministic,
                issue: .rootNotFound(root)
            )
        }

        var current = root
        var hops: [ProxySelectionHop] = []
        var certainty: ProxySelectionCertainty = .deterministic
        var visitedOrder: [String] = []
        var visitedIndexes: [String: Int] = [:]

        while true {
            if let start = visitedIndexes[current] {
                let cycle = Array(visitedOrder[start...]) + [current]
                return result(root, hops, nil, certainty, .cycle(cycle))
            }
            visitedIndexes[current] = visitedOrder.count
            visitedOrder.append(current)

            guard let vertex = topology.vertices[current] else {
                return result(root, hops, nil, certainty, .unresolvedReference(current))
            }
            if case .unresolved = vertex.kind {
                return result(root, hops, nil, certainty, .unresolvedReference(current))
            }

            switch vertex.kind {
            case let .group(groupKind):
                if groupKind == .loadBalance, vertex.fixed == nil {
                    certainty = max(certainty, .perConnection)
                    return result(
                        root,
                        hops,
                        nil,
                        certainty,
                        .loadBalance(group: vertex.name, candidates: vertex.children)
                    )
                }

                // `fixed` records the user's override preference, while `now` is the
                // effective runtime choice after health and availability decisions.
                guard let selected = vertex.now else {
                    return result(root, hops, nil, certainty, .noSelection(vertex.name))
                }
                let decision = selectionDecision(for: vertex, groupKind: groupKind)
                certainty = max(certainty, certaintyForDecision(decision))
                hops.append(
                    ProxySelectionHop(
                        source: vertex.name,
                        target: selected,
                        kind: .selection(decision)
                    )
                )
                current = selected

            case .endpoint:
                let dependency = dialerDependency(from: vertex.name, topology: topology)
                hops.append(contentsOf: dependency.hops)
                certainty = max(certainty, dependency.certainty)
                return result(root, hops, vertex.name, certainty, dependency.issue)

            case .unresolved:
                return result(root, hops, nil, certainty, .unresolvedReference(vertex.name))
            }
        }
    }

    private func dialerDependency(
        from endpoint: String,
        topology: ProxyTopology
    ) -> DialerDependencyResolution {
        var current = endpoint
        var visitedOrder: [String] = []
        var visitedIndexes: [String: Int] = [:]
        var hops: [ProxySelectionHop] = []
        var certainty: ProxySelectionCertainty = .deterministic

        while true {
            if let start = visitedIndexes[current] {
                let cycle = Array(visitedOrder[start...]) + [current]
                return DialerDependencyResolution(
                    hops: hops,
                    certainty: certainty,
                    issue: .dialerCycle(cycle)
                )
            }
            guard hops.count < 64 else {
                return DialerDependencyResolution(
                    hops: hops,
                    certainty: certainty,
                    issue: .dialerDepthLimit
                )
            }
            visitedIndexes[current] = visitedOrder.count
            visitedOrder.append(current)

            guard let vertex = topology.vertices[current] else {
                return DialerDependencyResolution(
                    hops: hops,
                    certainty: certainty,
                    issue: .dialerUnresolvedReference(current)
                )
            }
            switch vertex.kind {
            case let .group(groupKind):
                if groupKind == .loadBalance, vertex.fixed == nil {
                    return DialerDependencyResolution(
                        hops: hops,
                        certainty: .perConnection,
                        issue: .dialerLoadBalance(
                            group: vertex.name,
                            candidates: vertex.children
                        )
                    )
                }
                guard let selected = vertex.now else {
                    return DialerDependencyResolution(
                        hops: hops,
                        certainty: certainty,
                        issue: .dialerNoSelection(vertex.name)
                    )
                }
                let decision = selectionDecision(for: vertex, groupKind: groupKind)
                certainty = max(certainty, certaintyForDecision(decision))
                hops.append(
                    ProxySelectionHop(
                        source: vertex.name,
                        target: selected,
                        kind: .dialerSelection(decision)
                    )
                )
                current = selected
            case .endpoint:
                guard let dialer = vertex.dialerProxy else {
                    return DialerDependencyResolution(
                        hops: hops,
                        certainty: certainty,
                        issue: nil
                    )
                }
                hops.append(
                    ProxySelectionHop(source: vertex.name, target: dialer, kind: .dialer)
                )
                current = dialer
            case .unresolved:
                return DialerDependencyResolution(
                    hops: hops,
                    certainty: certainty,
                    issue: .dialerUnresolvedReference(vertex.name)
                )
            }
        }
    }

    private func selectionDecision(
        for vertex: ProxyTopologyVertex,
        groupKind: ProxyGroupKind
    ) -> ProxySelectionDecision {
        if vertex.fixed != nil { return .fixedOverride }
        switch groupKind {
        case .selector: return .selector
        case .urlTest: return .urlTest
        case .fallback: return .fallback
        case .relay: return .relay
        case .loadBalance: return .fixedOverride
        case let .other(type): return .automatic(type)
        }
    }

    private func certaintyForDecision(_ decision: ProxySelectionDecision) -> ProxySelectionCertainty {
        switch decision {
        case .selector:
            .deterministic
        case .urlTest, .fallback, .fixedOverride, .relay, .automatic:
            .automatic
        }
    }

    private func result(
        _ root: String,
        _ hops: [ProxySelectionHop],
        _ terminal: String?,
        _ certainty: ProxySelectionCertainty,
        _ issue: ProxySelectionPathIssue?
    ) -> ProxySelectionPath {
        ProxySelectionPath(
            root: root,
            hops: hops,
            terminal: terminal,
            certainty: certainty,
            issue: issue
        )
    }
}

private struct DialerDependencyResolution {
    let hops: [ProxySelectionHop]
    let certainty: ProxySelectionCertainty
    let issue: ProxySelectionPathIssue?
}
