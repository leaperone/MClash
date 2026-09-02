import Foundation

/// A controller-backed Proxies workspace for one real profile.
///
/// This is deliberately independent from `AppModel`'s legacy, app-wide proxy
/// presentation state. A caller can keep one snapshot per profile without
/// proxy/group names from different profiles colliding.
struct ProfileProxyWorkspaceSnapshot: Equatable, Sendable {
    let profileID: ProfileID
    let runtimeConfig: MihomoConfig
    let proxiesByName: [String: MihomoProxy]
    let proxyGroups: [MihomoProxy]
    let profileStructure: ProfileStructure
    let topology: ProxyTopology
    let selectionPaths: [String: ProxySelectionPath]
    let delays: [String: Int]

    func proxyGroups(forRoutingMode rawMode: String) -> [MihomoProxy] {
        switch rawMode.lowercased() {
        case "direct":
            return []
        case "global":
            return proxiesByName["GLOBAL"].map { [$0] } ?? []
        default:
            return proxyGroups
        }
    }

    func delay(for proxy: String) -> Int? {
        delays[proxy]
            ?? proxiesByName[proxy]?.history.last(where: { $0.delay > 0 })?.delay
    }
}

enum ProfileProxyWorkspaceUnavailability: Equatable, Sendable {
    case profileNotFound
    case dedicatedPortDisabled(port: Int?)
    case primaryControllerNotReady
    case controllerStopped
    case controllerTransitioning
    case controllerFailed(String)
}

/// Observable loading state for one real Profile's Proxies workspace.
///
/// `failed` retains the previous snapshot so UI can keep stable layout while
/// clearly indicating that its data could not be refreshed.
enum ProfileProxyWorkspaceState: Equatable, Sendable {
    case idle
    case loading(previous: ProfileProxyWorkspaceSnapshot?)
    case ready(ProfileProxyWorkspaceSnapshot)
    case unavailable(ProfileProxyWorkspaceUnavailability)
    case failed(message: String, previous: ProfileProxyWorkspaceSnapshot?)

    var snapshot: ProfileProxyWorkspaceSnapshot? {
        switch self {
        case let .ready(snapshot):
            snapshot
        case let .loading(previous), let .failed(_, previous):
            previous
        case .idle, .unavailable:
            nil
        }
    }

}

/// Profile-scoped identity for a pending proxy selection.
struct ProfileProxySelectionKey: Hashable, Sendable {
    let profileID: ProfileID
    let group: String
}

/// Pure projection of a Mihomo controller response into the model consumed by
/// the List and Topology presentations.
struct ProfileProxyWorkspaceSnapshotBuilder: Sendable {
    func build(
        profileID: ProfileID,
        runtimeConfig: MihomoConfig,
        collection: MihomoProxyCollection,
        profileStructure: ProfileStructure,
        measuredDelays: [String: Int] = [:]
    ) -> ProfileProxyWorkspaceSnapshot {
        let topology = ProxyTopologyBuilder().build(
            collection: collection,
            profileStructure: profileStructure
        )
        let selectionPaths = Dictionary(
            uniqueKeysWithValues: topology.groupOrder.map { groupName in
                (
                    groupName,
                    ProxySelectionPathResolver().resolve(
                        from: groupName,
                        topology: topology
                    )
                )
            }
        )
        let currentNames = Set(collection.proxies.keys)
        var delays = measuredDelays.filter { currentNames.contains($0.key) }
        for proxy in collection.proxies.values {
            if let delay = proxy.history.last?.delay {
                if delay > 0 {
                    delays[proxy.name] = delay
                } else {
                    delays[proxy.name] = nil
                }
            }
        }
        let groups: [MihomoProxy] = topology.visibleGroupOrder.compactMap { name in
            guard name != "GLOBAL" else { return nil }
            return collection.proxies[name]
        }
        return ProfileProxyWorkspaceSnapshot(
            profileID: profileID,
            runtimeConfig: runtimeConfig,
            proxiesByName: collection.proxies,
            proxyGroups: groups,
            profileStructure: profileStructure,
            topology: topology,
            selectionPaths: selectionPaths,
            delays: delays
        )
    }
}

/// Connector-neutral read/write seam for a profile's controller-backed
/// workspace. The UI and workspace orchestration depend on this contract
/// rather than a particular core implementation. Mihomo is currently the
/// adapter behind it; a native controller can implement the same contract
/// without changing the presentation layer.
protocol ProfileProxyControllerClient: Sendable {
    func fetchConfig() async throws -> MihomoConfig
    func fetchProxies() async throws -> MihomoProxyCollection
    func selectProxy(group: String, proxy: String) async throws
    func clearProxyOverride(group: String) async throws
    func patchConfig(_ patch: MihomoConfigPatch) async throws
    func closeAllConnections() async throws
    func measureDelay(
        proxy: String,
        targetURL: URL,
        timeoutMilliseconds: Int,
        expectedStatus: String?
    ) async throws -> Int
}

/// Keeps the legacy controller implementation behind the connector-neutral
/// profile workspace contract. The conformance lives beside the protocol so
/// minimal Mihomo API smoke builds do not need to compile the entire app UI.
extension MihomoAPIClient: ProfileProxyControllerClient {}

extension ProfileProxyControllerClient {
    func measureDelay(
        proxy: String,
        targetURL: URL,
        timeoutMilliseconds: Int = 5_000,
        expectedStatus: String? = nil
    ) async throws -> Int {
        try await measureDelay(
            proxy: proxy,
            targetURL: targetURL,
            timeoutMilliseconds: timeoutMilliseconds,
            expectedStatus: expectedStatus
        )
    }
}

/// Internal seam used by model tests. Production resolution always inspects
/// the existing primary controller or the already-running auxiliary fleet.
enum ProfileProxyControllerResolution: Sendable {
    case available(any ProfileProxyControllerClient)
    case unavailable(ProfileProxyWorkspaceUnavailability)
}

typealias ProfileProxyControllerResolver =
    @MainActor @Sendable (ProfileID) async -> ProfileProxyControllerResolution
