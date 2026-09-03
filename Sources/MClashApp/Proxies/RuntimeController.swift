import Foundation

/// The small, connector-neutral status surface exposed to presentation code.
///
/// A runtime controller may be backed by native connectors or by the legacy
/// Mihomo adapter.  Consumers must not need to know which one produced the
/// status in order to render a workspace status indicator.
struct RuntimeControllerStatus: Equatable, Sendable {
    enum State: String, Equatable, Sendable {
        case running
        case stopped
    }

    let state: State
    let routingMode: String?
    let backend: String

    var isRunning: Bool { state == .running }
}

/// A normalized rule summary for status and diagnostics surfaces.  The full
/// rule representation remains an implementation detail of each connector.
struct RuntimeRuleSummary: Equatable, Sendable, Identifiable {
    let id: String
    let kind: String
    let matcher: String
    let outbound: String
    let hitCount: UInt64?
}

/// Connector-neutral controller contract used by AppModel/UI read paths.
///
/// Mutating operations intentionally stay limited to proxy selection.  More
/// invasive runtime changes continue through the existing profile adapter
/// until their native equivalents are ready.
protocol RuntimeControllerClient: Sendable {
    func fetchRuntimeStatus() async throws -> RuntimeControllerStatus
    func fetchRuntimeRules() async throws -> [RuntimeRuleSummary]
    func fetchWorkspaceProjection() async throws -> ProxyWorkspaceProjection
    func selectWorkspaceRoute(group: String, member: String) async throws
    func clearWorkspaceRoute(group: String) async throws
}
