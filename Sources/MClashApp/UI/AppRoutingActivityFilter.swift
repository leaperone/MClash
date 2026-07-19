import MClashNetworkShared

enum AppRoutingActivityFilter: String, CaseIterable, Identifiable, Sendable {
    case focused = "Proxy & Issues"
    case all = "All"
    case active = "Active"
    case viaMihomo = "Via Mihomo"
    case direct = "Direct"
    case rejected = "Rejected"
    case failed = "Failed"

    var id: Self { self }

    func includes(_ activity: AppRoutingActivity) -> Bool {
        switch self {
        case .focused:
            return Self.isProxyOrIssue(activity)
        case .all:
            return true
        case .active:
            return activity.endedAt == nil
                && activity.relayState != .completed
                && activity.relayState != .failed
        case .viaMihomo:
            if case .mihomo = activity.effectiveAction {
                return activity.relayState != .failed
            }
            return false
        case .direct:
            return activity.effectiveAction == .direct
                || activity.effectiveAction == .failOpen
        case .rejected:
            return activity.effectiveAction == .reject
        case .failed:
            return activity.relayState == .failed
        }
    }

    private static func isProxyOrIssue(_ activity: AppRoutingActivity) -> Bool {
        if activity.relayState == .failed { return true }

        switch activity.effectiveAction {
        case .mihomo, .reject, .failOpen:
            return true
        case .direct:
            // A Mihomo route that fell back to Direct is important diagnostic
            // evidence. Hide only ordinary Direct traffic in the focused view.
            switch activity.configuredAction {
            case .direct:
                return false
            case .mihomo, .reject:
                return true
            }
        }
    }
}
