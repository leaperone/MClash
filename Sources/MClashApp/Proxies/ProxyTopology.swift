import Foundation

enum ProxyGroupKind: Equatable, Hashable, Sendable {
    case selector
    case urlTest
    case fallback
    case loadBalance
    case relay
    case other(String)

    init(rawType: String) {
        let normalized = rawType
            .lowercased()
            .filter { $0.isLetter || $0.isNumber }
        switch normalized {
        case "selector", "select":
            self = .selector
        case "urltest":
            self = .urlTest
        case "fallback":
            self = .fallback
        case "loadbalance":
            self = .loadBalance
        case "relay":
            self = .relay
        default:
            self = .other(rawType)
        }
    }

    var isKnownGroup: Bool {
        switch self {
        case .selector, .urlTest, .fallback, .loadBalance, .relay:
            true
        case .other:
            false
        }
    }
}

enum ProxyTopologyVertexKind: Equatable, Hashable, Sendable {
    case group(ProxyGroupKind)
    case endpoint
    case unresolved
}

struct ProxyTopologyVertex: Equatable, Sendable, Identifiable {
    let id: String
    let name: String
    let type: String
    let kind: ProxyTopologyVertexKind
    let children: [String]
    let now: String?
    let fixed: String?
    let dialerProxy: String?
    let providerName: String?
    let hidden: Bool
    let alive: Bool

    var isGroup: Bool {
        if case .group = kind { return true }
        return false
    }
}

enum ProxyTopologyEdgeKind: String, Equatable, Hashable, Sendable {
    case member
    case dialer
}

struct ProxyTopologyEdge: Equatable, Hashable, Sendable {
    let source: String
    let target: String
    let kind: ProxyTopologyEdgeKind
}

struct ProxyTopologyCycle: Equatable, Hashable, Sendable {
    /// The first node is repeated at the end so consumers can render a closed path directly.
    let nodes: [String]
}

struct ProxyTopology: Equatable, Sendable {
    let vertices: [String: ProxyTopologyVertex]
    let edges: [ProxyTopologyEdge]
    /// All runtime groups, in profile order when available and deterministic fallback order otherwise.
    let groupOrder: [String]
    let visibleGroupOrder: [String]
    let childrenByGroup: [String: [String]]
    /// Parents include both membership and dialer dependency edges.
    let parentsByChild: [String: [String]]
    let roots: [String]
    let unresolved: Set<String>
    let cycles: [ProxyTopologyCycle]

    static let empty = ProxyTopology(
        vertices: [:],
        edges: [],
        groupOrder: [],
        visibleGroupOrder: [],
        childrenByGroup: [:],
        parentsByChild: [:],
        roots: [],
        unresolved: [],
        cycles: []
    )

    func vertex(named name: String) -> ProxyTopologyVertex? {
        vertices[name]
    }

    func edges(from source: String, kind: ProxyTopologyEdgeKind? = nil) -> [ProxyTopologyEdge] {
        edges.filter { edge in
            edge.source == source && (kind == nil || edge.kind == kind)
        }
    }
}

func proxyStableNameKey(_ value: String) -> String {
    value.folding(
        options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
        locale: Locale(identifier: "en_US_POSIX")
    )
}

func proxyStableNameComesBefore(_ lhs: String, _ rhs: String) -> Bool {
    let leftKey = proxyStableNameKey(lhs)
    let rightKey = proxyStableNameKey(rhs)
    if leftKey != rightKey { return leftKey < rightKey }
    return lhs < rhs
}
