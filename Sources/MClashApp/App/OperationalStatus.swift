import Foundation
import MClashNetworkShared

/// One user-actionable problem in MClash's current operating state.
///
/// The model intentionally keeps concurrent subsystem failures separate. A
/// system-proxy restore failure must not hide an App Routing provider failure,
/// and neither should be reduced to an unexplained red badge.
struct OperationalIssue: Identifiable, Equatable, Sendable {
    enum Severity: Int, Comparable, Sendable {
        case information = 0
        case warning = 1
        case error = 2

        static func < (lhs: Self, rhs: Self) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    enum Subsystem: String, Sendable {
        case core = "mihomo Core"
        case controller = "Controller"
        case systemProxy = "System Proxy"
        case appRouting = "App Routing"
        case liveData = "Live Data"
        case rules = "Mihomo Rules"
        case providers = "Providers"
        case trafficHistory = "Traffic History"
        case application = "Application"
    }

    enum Action: Equatable, Sendable {
        case reconnect
        case restoreSystemProxy
        case retryAppRouting
        case openAppRouting
        case openRules
        case openProviders
        case openTraffic
        case openLogs
    }

    let id: String
    let severity: Severity
    let subsystem: Subsystem
    let title: String
    let consequence: String
    let technicalDetail: String?
    let primaryActionTitle: String?
    let primaryAction: Action?
    let secondaryActionTitle: String?
    let secondaryAction: Action?

    init(
        id: String,
        severity: Severity,
        subsystem: Subsystem,
        title: String,
        consequence: String,
        technicalDetail: String? = nil,
        primaryActionTitle: String? = nil,
        primaryAction: Action? = nil,
        secondaryActionTitle: String? = "View Logs",
        secondaryAction: Action? = .openLogs
    ) {
        self.id = id
        self.severity = severity
        self.subsystem = subsystem
        self.title = title
        self.consequence = consequence
        self.technicalDetail = technicalDetail
        self.primaryActionTitle = primaryActionTitle
        self.primaryAction = primaryAction
        self.secondaryActionTitle = secondaryActionTitle
        self.secondaryAction = secondaryAction
    }
}

/// The single operating truth used by Overview, the sidebar, and the menu bar.
struct OperationalSnapshot: Equatable, Sendable {
    enum Level: Equatable, Sendable {
        case disconnected
        case transitioning
        case localOnly
        case active
        case attention
    }

    let level: Level
    let title: String
    let detail: String
    let captureSummary: String
    let activeCaptureCount: Int
    let activeRuleCount: Int
    /// Latest connection for which Mihomo reported a non-DIRECT terminal route.
    /// This is route evidence, not proof that a particular macOS capture plane
    /// originated the flow.
    let latestNonDirectRouteAt: Date?
    let issueCount: Int
}

extension AppModel {
    var operationalIssues: [OperationalIssue] {
        var issues: [OperationalIssue] = []

        for failure in storageInitializationFailures {
            issues.append(
                OperationalIssue(
                    id: "storage.\(failure.component.issueIdentifier)",
                    severity: .error,
                    subsystem: .application,
                    title: failure.component.issueTitle,
                    consequence: failure.component.userConsequence,
                    technicalDetail: "\(failure.reason)\n\nRecovery: \(failure.recoverySuggestion)\nDetected: \(failure.occurredAt.formatted(date: .abbreviated, time: .standard))",
                    primaryActionTitle: "View Recovery Log",
                    primaryAction: .openLogs,
                    secondaryActionTitle: nil,
                    secondaryAction: nil
                )
            )
        }

        if case let .failed(message) = coreState {
            issues.append(
                OperationalIssue(
                    id: "core.failed",
                    severity: .error,
                    subsystem: .core,
                    title: "The proxy core is not running",
                    consequence: "No new traffic can be routed through Mihomo until the core reconnects.",
                    technicalDetail: message,
                    primaryActionTitle: "Reconnect",
                    primaryAction: .reconnect
                )
            )
        }

        if case let .degraded(message) = controllerState {
            issues.append(
                OperationalIssue(
                    id: "controller.degraded",
                    severity: .error,
                    subsystem: .controller,
                    title: "Mihomo controls are unavailable",
                    consequence: "Routing may continue, but MClash cannot verify routes, connections, or live statistics.",
                    technicalDetail: message,
                    primaryActionTitle: "Reconnect",
                    primaryAction: .reconnect
                )
            )
        }

        if let guardFailure = systemProxyGuardFailure {
            issues.append(
                OperationalIssue(
                    id: "system-proxy.guard",
                    severity: guardFailure.consecutiveFailures >= Self.systemProxyGuardFailureThreshold
                        ? .error
                        : .warning,
                    subsystem: .systemProxy,
                    title: guardFailure.consecutiveFailures >= Self.systemProxyGuardFailureThreshold
                        ? "The macOS system proxy is unverified"
                        : "System proxy verification is retrying",
                    consequence: "MClash cannot currently confirm that macOS traffic is still being sent to its local proxy. Routing may be bypassed or interrupted.",
                    technicalDetail: "\(guardFailure.consecutiveFailures) consecutive verification failures. Last attempt: \(guardFailure.lastFailureAt.formatted(date: .abbreviated, time: .standard)). Last error: \(guardFailure.reason)",
                    primaryActionTitle: guardFailure.consecutiveFailures
                        >= Self.systemProxyGuardFailureThreshold
                        ? "Turn Off & Restore"
                        : "View Logs",
                    primaryAction: guardFailure.consecutiveFailures
                        >= Self.systemProxyGuardFailureThreshold
                        ? .restoreSystemProxy
                        : .openLogs,
                    secondaryActionTitle: guardFailure.consecutiveFailures
                        >= Self.systemProxyGuardFailureThreshold
                        ? "View Logs"
                        : nil,
                    secondaryAction: guardFailure.consecutiveFailures
                        >= Self.systemProxyGuardFailureThreshold
                        ? .openLogs
                        : nil
                )
            )
        } else if case let .failed(message) = systemProxyState {
            issues.append(
                OperationalIssue(
                    id: "system-proxy.failed",
                    severity: .error,
                    subsystem: .systemProxy,
                    title: "Previous macOS proxy settings need to be restored",
                    consequence: "Network access may remain pointed at a local listener until restoration succeeds.",
                    technicalDetail: message,
                    primaryActionTitle: "Restore Now",
                    primaryAction: .restoreSystemProxy
                )
            )
        }

        switch networkCaptureState {
        case .awaitingUserApproval:
            issues.append(
                OperationalIssue(
                    id: "app-routing.approval",
                    severity: .warning,
                    subsystem: .appRouting,
                    title: "App Routing is waiting for macOS approval",
                    consequence: "Application rules are saved but are not intercepting traffic yet.",
                    primaryActionTitle: "Review App Routing",
                    primaryAction: .openAppRouting,
                    secondaryActionTitle: nil,
                    secondaryAction: nil
                )
            )
        case .requiresReboot:
            issues.append(
                OperationalIssue(
                    id: "app-routing.reboot",
                    severity: .warning,
                    subsystem: .appRouting,
                    title: "A Mac restart is required for App Routing",
                    consequence: "Application rules will remain inactive until the Network Extension update finishes.",
                    primaryActionTitle: "Review App Routing",
                    primaryAction: .openAppRouting,
                    secondaryActionTitle: nil,
                    secondaryAction: nil
                )
            )
        case let .failed(message):
            issues.append(
                OperationalIssue(
                    id: "app-routing.failed",
                    severity: .error,
                    subsystem: .appRouting,
                    title: "App Routing is not intercepting traffic",
                    consequence: "Per-application rules are currently not being applied.",
                    technicalDetail: message,
                    primaryActionTitle: "Retry",
                    primaryAction: .retryAppRouting
                )
            )
        case .off, .waitingForConnection, .enabling, .on, .disabling:
            break
        }

        if let networkCaptureRollbackFailure {
            issues.append(
                OperationalIssue(
                    id: "app-routing.rollback",
                    severity: .error,
                    subsystem: .appRouting,
                    title: "A previous network state could not be fully restored",
                    consequence: "App Routing, the mihomo core, or the macOS System Proxy may not match the state from before the failed change.",
                    technicalDetail: networkCaptureRollbackFailure,
                    primaryActionTitle: "View Recovery Log",
                    primaryAction: .openLogs,
                    secondaryActionTitle: nil,
                    secondaryAction: nil
                )
            )
        }

        if networkCapturePreferences.enabled,
           networkCapturePreferences.dnsEnabled,
           dnsProxyAutomaticallyDisabled || dnsProxyRuntimeError != nil {
            let restored = dnsProxyAutomaticallyDisabled
            issues.append(
                OperationalIssue(
                    id: "app-routing.dns",
                    severity: .error,
                    subsystem: .appRouting,
                    title: restored
                        ? "App Routing stopped after DNS verification failed"
                        : "DNS routing is unverified",
                    consequence: restored
                        ? "MClash stopped application capture and DNS together; macOS system DNS was restored."
                        : "MClash cannot confirm that ordinary DNS is reaching its private Mihomo listener.",
                    technicalDetail: dnsProxyRuntimeError,
                    primaryActionTitle: "Retry App Routing",
                    primaryAction: .openAppRouting,
                    secondaryActionTitle: "View Logs",
                    secondaryAction: .openLogs
                )
            )
        }

        for stream in degradedStreams.sorted(by: { $0.presentationTitle < $1.presentationTitle }) {
            issues.append(
                OperationalIssue(
                    id: "live-data.\(stream.presentationIdentifier)",
                    severity: stream == .connections || stream == .traffic ? .warning : .information,
                    subsystem: .liveData,
                    title: "\(stream.presentationTitle) data is reconnecting",
                    consequence: stream.staleDataConsequence,
                    technicalDetail: liveStreamHealth[stream]?.lastError,
                    primaryActionTitle: stream == .appRouting ? "Open Activity" : "View Logs",
                    primaryAction: stream == .appRouting ? .openAppRouting : .openLogs,
                    secondaryActionTitle: nil,
                    secondaryAction: nil
                )
            )
        }

        if let rulesErrorMessage {
            issues.append(
                OperationalIssue(
                    id: "rules.load",
                    severity: .warning,
                    subsystem: .rules,
                    title: "Mihomo rules could not be loaded",
                    consequence: "The core may still route traffic, but MClash cannot explain or inspect the active rule set.",
                    technicalDetail: rulesErrorMessage,
                    primaryActionTitle: "Open Rules",
                    primaryAction: .openRules
                )
            )
        }

        if let providersErrorMessage {
            issues.append(
                OperationalIssue(
                    id: "providers.load",
                    severity: .warning,
                    subsystem: .providers,
                    title: "Some providers could not be loaded",
                    consequence: "Provider freshness and availability may be incomplete.",
                    technicalDetail: providersErrorMessage,
                    primaryActionTitle: "Open Providers",
                    primaryAction: .openProviders
                )
            )
        }

        if case let .unavailable(message) = trafficHistoryRuntimeState {
            issues.append(
                OperationalIssue(
                    id: "traffic-history.unavailable",
                    severity: .warning,
                    subsystem: .trafficHistory,
                    title: "Persistent traffic history is unavailable",
                    consequence: "Live and in-memory traffic remain visible, but Today and This Week totals are not being saved.",
                    technicalDetail: message,
                    primaryActionTitle: "Open Traffic",
                    primaryAction: .openTraffic,
                    secondaryActionTitle: nil,
                    secondaryAction: nil
                )
            )
        }

        return issues.sorted {
            if $0.severity != $1.severity { return $0.severity > $1.severity }
            return $0.id < $1.id
        }
    }

    var operationalSnapshot: OperationalSnapshot {
        let issues = operationalIssues
        let systemProxyIsOn: Bool = {
            if case .on = systemProxyState { return true }
            return false
        }()
        let appRoutingIsOn: Bool = {
            if case .on = networkCaptureState { return true }
            return false
        }()
        let activeCaptureCount = (systemProxyIsOn ? 1 : 0) + (appRoutingIsOn ? 1 : 0)
        let activeRuleCount = networkCapturePreferences.snapshot.rules.filter(\.enabled).count
        let latestRouteAt = flowLedger.latestNonDirectRouteAt

        let captureSummary: String
        switch (systemProxyIsOn, appRoutingIsOn) {
        case (true, true):
            captureSummary = "System Proxy + App Routing"
        case (true, false):
            captureSummary = "System Proxy"
        case (false, true):
            captureSummary = "App Routing · \(activeRuleCount) active \(activeRuleCount == 1 ? "rule" : "rules")"
        case (false, false):
            captureSummary = isConnected ? "Local proxy listeners only" : "Traffic capture off"
        }

        if !issues.filter({ $0.severity == .error }).isEmpty {
            return OperationalSnapshot(
                level: .attention,
                title: "Routing needs attention",
                detail: issues[0].consequence,
                captureSummary: captureSummary,
                activeCaptureCount: activeCaptureCount,
                activeRuleCount: activeRuleCount,
                latestNonDirectRouteAt: latestRouteAt,
                issueCount: issues.count
            )
        }

        if preparationInProgress || isBusy || networkStateTransitionInProgress {
            return OperationalSnapshot(
                level: .transitioning,
                title: "Preparing routing state",
                detail: "MClash is applying a network change and will verify the resulting state.",
                captureSummary: captureSummary,
                activeCaptureCount: activeCaptureCount,
                activeRuleCount: activeRuleCount,
                latestNonDirectRouteAt: latestRouteAt,
                issueCount: issues.count
            )
        }

        guard isConnected else {
            return OperationalSnapshot(
                level: .disconnected,
                title: "Traffic capture is off",
                detail: activeProfile == nil
                    ? "Choose a profile to start routing traffic."
                    : "The selected profile is ready when you want to connect.",
                captureSummary: captureSummary,
                activeCaptureCount: activeCaptureCount,
                activeRuleCount: activeRuleCount,
                latestNonDirectRouteAt: latestRouteAt,
                issueCount: issues.count
            )
        }

        guard activeCaptureCount > 0 else {
            return OperationalSnapshot(
                level: .localOnly,
                title: "Core ready · macOS capture off",
                detail: "Only apps explicitly configured to use MClash's local proxy listeners are routed.",
                captureSummary: captureSummary,
                activeCaptureCount: activeCaptureCount,
                activeRuleCount: activeRuleCount,
                latestNonDirectRouteAt: latestRouteAt,
                issueCount: issues.count
            )
        }

        return OperationalSnapshot(
            level: issues.isEmpty ? .active : .attention,
            title: issues.isEmpty ? "Traffic routing is active" : "Routing is active with warnings",
            detail: latestRouteAt.map {
                "Mihomo last reported a non-direct route \($0.formatted(.relative(presentation: .named)))."
            } ?? "Capture configuration is verified; Mihomo has not yet reported a non-direct route.",
            captureSummary: captureSummary,
            activeCaptureCount: activeCaptureCount,
            activeRuleCount: activeRuleCount,
            latestNonDirectRouteAt: latestRouteAt,
            issueCount: issues.count
        )
    }

}

private extension AppModel.StorageInitializationFailure.Component {
    var issueIdentifier: String {
        switch self {
        case .applicationState: "application-state"
        case .profiles: "profiles"
        case .runtimeOverrides: "runtime-overrides"
        case .systemProxySettings: "system-proxy-settings"
        case .appRoutingSettings: "app-routing-settings"
        case .profileRuntimePlan: "profile-runtime-plan"
        }
    }

    var issueTitle: String {
        switch self {
        case .applicationState: "MClash cannot open its application data"
        case .profiles: "Saved profiles could not be opened"
        case .runtimeOverrides: "Runtime settings storage is unavailable"
        case .systemProxySettings: "System proxy settings storage is unavailable"
        case .appRoutingSettings: "App Routing settings storage is unavailable"
        case .profileRuntimePlan: "The multi-profile runtime plan was reset safely"
        }
    }

    var userConsequence: String {
        switch self {
        case .applicationState:
            "Profiles and settings are unavailable. Empty screens do not mean the saved data was deleted."
        case .profiles:
            "MClash cannot read or save profiles. An empty profile list does not mean your profiles were deleted."
        case .runtimeOverrides:
            "Listener and runtime overrides cannot be read or saved, so displayed defaults may not represent your saved choices."
        case .systemProxySettings:
            "System proxy preferences cannot be read or saved; MClash will not silently claim those settings are available."
        case .appRoutingSettings:
            "Saved App Routing rules cannot be read or changed, so per-application capture must not be trusted."
        case .profileRuntimePlan:
            "The invalid multi-profile session plan was preserved for recovery. MClash regenerated only the current default session; review auxiliary sessions and Mixed ports before using them again."
        }
    }
}

private extension AppModel.LiveStream {
    var presentationIdentifier: String {
        switch self {
        case .traffic: "traffic"
        case .connections: "connections"
        case .logs: "logs"
        case .proxies: "proxies"
        case .appRouting: "app-routing"
        }
    }

    var presentationTitle: String {
        switch self {
        case .traffic: "Traffic rate"
        case .connections: "Connection"
        case .logs: "Log"
        case .proxies: "Proxy state"
        case .appRouting: "App Routing activity"
        }
    }

    var staleDataConsequence: String {
        switch self {
        case .traffic:
            "The displayed upload and download rates may be stale until the stream reconnects."
        case .connections:
            "The displayed active connection count and routes may be stale until the stream reconnects."
        case .logs:
            "New Mihomo log entries may be missing until the stream reconnects."
        case .proxies:
            "Node selections, health, and delay information may be stale."
        case .appRouting:
            "Flow decisions and App Routing byte counts may be stale until the provider responds."
        }
    }
}
