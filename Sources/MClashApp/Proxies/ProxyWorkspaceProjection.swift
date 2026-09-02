import Foundation

/// The stable health information presented by the proxy workspace.
///
/// This intentionally does not expose the response shape of a particular
/// core.  A native connector can produce the same projection as the current
/// controller adapter without importing any controller models.
struct ProxyWorkspaceNodeHealth: Equatable, Sendable, Identifiable {
    let id: String
    let name: String
    let isAlive: Bool
    let latencyMilliseconds: Int?
    let providerName: String?
    let lastCheckedAt: String?

    init(
        id: String,
        name: String,
        isAlive: Bool,
        latencyMilliseconds: Int? = nil,
        providerName: String? = nil,
        lastCheckedAt: String? = nil
    ) {
        self.id = id
        self.name = name
        self.isAlive = isAlive
        self.latencyMilliseconds = latencyMilliseconds
        self.providerName = providerName
        self.lastCheckedAt = lastCheckedAt
    }
}

enum ProxyWorkspaceGroupStrategy: Equatable, Sendable {
    case selector
    case urlTest
    case fallback
    case loadBalance
    case relay
    case other(String)

    init(rawValue: String) {
        switch rawValue.lowercased().filter({ $0.isLetter || $0.isNumber }) {
        case "selector", "select": self = .selector
        case "urltest": self = .urlTest
        case "fallback": self = .fallback
        case "loadbalance": self = .loadBalance
        case "relay": self = .relay
        default: self = .other(rawValue)
        }
    }

    var supportsSelection: Bool {
        switch self {
        case .selector, .urlTest, .fallback: true
        case .loadBalance, .relay, .other: false
        }
    }
}

/// A group as understood by the MClash workspace, independent of a runtime
/// controller's JSON model.
struct ProxyWorkspaceGroupProjection: Equatable, Sendable, Identifiable {
    let id: String
    let name: String
    let strategy: ProxyWorkspaceGroupStrategy
    let memberIDs: [String]
    let selectedMemberID: String?
    let fixedMemberID: String?
    let isAutomaticSelection: Bool

    init(
        id: String,
        name: String,
        strategy: ProxyWorkspaceGroupStrategy,
        memberIDs: [String],
        selectedMemberID: String? = nil,
        fixedMemberID: String? = nil,
        isAutomaticSelection: Bool? = nil
    ) {
        self.id = id
        self.name = name
        self.strategy = strategy
        self.memberIDs = memberIDs
        self.selectedMemberID = selectedMemberID
        self.fixedMemberID = fixedMemberID
        self.isAutomaticSelection = isAutomaticSelection ?? (fixedMemberID == nil)
    }
}

/// Connector-neutral projection consumed by the profile proxy workspace.
struct ProxyWorkspaceProjection: Equatable, Sendable {
    let nodes: [String: ProxyWorkspaceNodeHealth]
    let groups: [ProxyWorkspaceGroupProjection]

    init(
        nodes: [String: ProxyWorkspaceNodeHealth],
        groups: [ProxyWorkspaceGroupProjection]
    ) {
        self.nodes = nodes
        self.groups = groups
    }

    /// Builds the projection at the controller adapter boundary.  This is the
    /// only place where the legacy response's group/node distinction is read.
    init(collection: MihomoProxyCollection) {
        let values = collection.proxies.values
        let groupNames = Set(values.filter { !$0.all.isEmpty || ProxyGroupKind(rawType: $0.type).isKnownGroup }.map(\.name))
        var nodes: [String: ProxyWorkspaceNodeHealth] = [:]
        for proxy in values where !groupNames.contains(proxy.name) {
            let latest = proxy.history.last(where: { $0.delay > 0 })
            nodes[proxy.name] = ProxyWorkspaceNodeHealth(
                id: proxy.id ?? proxy.name,
                name: proxy.name,
                isAlive: proxy.alive,
                latencyMilliseconds: latest?.delay,
                providerName: proxy.providerName,
                lastCheckedAt: latest?.time
            )
        }

        let groups = values
            .filter { groupNames.contains($0.name) }
            .sorted { proxyStableNameComesBefore($0.name, $1.name) }
            .map { proxy in
                let fixed = proxy.fixedOverride
                return ProxyWorkspaceGroupProjection(
                    id: proxy.id ?? proxy.name,
                    name: proxy.name,
                    strategy: ProxyWorkspaceGroupStrategy(rawValue: proxy.type),
                    memberIDs: proxy.all,
                    selectedMemberID: proxy.now,
                    fixedMemberID: fixed,
                    isAutomaticSelection: fixed == nil
                )
            }
        self.init(nodes: nodes, groups: groups)
    }

    func group(named name: String) -> ProxyWorkspaceGroupProjection? {
        groups.first { $0.name == name }
    }
}

/// Connector-neutral operations required by the profile workspace.  The
/// existing controller protocol below remains available during migration.
protocol ProfileProxyWorkspaceClient: Sendable {
    func fetchWorkspaceProjection() async throws -> ProxyWorkspaceProjection
    func selectWorkspaceRoute(group: String, member: String) async throws
    func clearWorkspaceRoute(group: String) async throws
}
