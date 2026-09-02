import AppKit
import Foundation
import MClashAutomationProtocol
import MClashNetworkShared
import Observation
import Security

@MainActor
@Observable
final class AppModel {
    struct StorageInitializationFailure: Identifiable, Equatable, Sendable {
        enum Component: String, Hashable, Sendable {
            case applicationState = "Application State"
            case profiles = "Profiles"
            case runtimeOverrides = "Runtime Settings"
            case systemProxySettings = "System Proxy Settings"
            case appRoutingSettings = "App Routing Settings"
            case profileRuntimePlan = "Profile Runtime Plan"
            case configuration = "Configuration"
        }

        let component: Component
        let occurredAt: Date
        let reason: String
        let recoverySuggestion: String

        var id: String { component.rawValue }
    }

    struct SystemProxyGuardFailure: Equatable, Sendable {
        let consecutiveFailures: Int
        let firstFailureAt: Date
        let lastFailureAt: Date
        let reason: String
    }

    private struct ProxyDelayContextKey: Hashable {
        let group: String
        let proxy: String
        let targetURL: URL
    }

    struct TrafficSample: Identifiable, Equatable {
        let id = UUID()
        let timestamp: Date
        let download: Int64
        let upload: Int64
    }

    struct AppRoutingRuleStatistics: Equatable, Sendable {
        static let zero = AppRoutingRuleStatistics()

        var matchCount = 0
        var activeCount = 0
        var failureCount = 0
        var measuredBytes: UInt64 = 0
        var unmeasuredCount = 0
        var lastMatchedAt: Date?
    }

    private struct AppRoutingActivityProcessingResult: Sendable {
        let activities: [AppRoutingActivity]
        let activitiesByIdentifier: [UUID: AppRoutingActivity]
        let ruleStatistics: [String: AppRoutingRuleStatistics]
        let rateTracker: AppRoutingTrafficRateTracker
        let trafficRates: AppRoutingTrafficRateSnapshot
        let activeCount: Int
        let removedCount: Int
        let mergedUpdates: Bool
        let needsAccounting: Bool
    }

    struct ClosedConnectionRecord: Identifiable {
        let id = UUID()
        let connection: MihomoConnection
        let closedAt: Date
    }

    private struct StoredProfileSnapshot {
        let metadata: ProfileMetadata
        let configurationData: Data
    }

    enum ControllerState: Equatable {
        case idle
        case loading
        case ready
        case degraded(String)
    }

    enum LiveStream: CaseIterable, Hashable {
        case traffic
        case connections
        case logs
        case proxies
        case appRouting

        var freshnessDescription: String {
            switch self {
            case .traffic: AppLocalization.string("traffic rate")
            case .connections: AppLocalization.string("connection")
            case .logs: AppLocalization.string("log")
            case .proxies: AppLocalization.string("proxy state")
            case .appRouting: AppLocalization.string("App Routing activity")
            }
        }
    }

    enum MenuBarDisplayStyle: String, CaseIterable, Identifiable, Sendable {
        case logo
        case proxyStatus

        var id: Self { self }

        var title: String {
            switch self {
            case .logo: "Network Icon"
            case .proxyStatus: "Proxy Status"
            }
        }
    }

    struct PresentationTelemetryPolicy: Equatable, Sendable {
        var traffic = false
        var connections = false
        var logs = false
        var proxies = false
        var appRoutingActivity = false

        var hasControllerStreams: Bool {
            traffic || connections || logs || proxies
        }

        func dnsProxyRuntimePollInterval(lightweightMode: Bool) -> Duration {
            if appRoutingActivity { return .seconds(2) }
            return lightweightMode ? .seconds(10) : .seconds(5)
        }

        static func resolve(
            mainWindowVisible: Bool,
            menuBarContentVisible: Bool,
            destination: Destination?,
            appRoutingActivityVisible: Bool,
            menuBarStatusVisible: Bool = false
        ) -> Self {
            var policy = Self()

            if menuBarContentVisible {
                policy.traffic = true
                policy.connections = true
                policy.proxies = true
            }
            if menuBarStatusVisible {
                policy.traffic = true
                policy.connections = true
            }

            guard mainWindowVisible else { return policy }
            switch destination ?? .overview {
            case .overview:
                policy.traffic = true
                policy.connections = true
                policy.appRoutingActivity = true
            case .workspaces, .nodes, .sources, .entrances, .proxyGroups, .dns:
                break
            case .proxies:
                policy.connections = true
                policy.proxies = true
            case .appRouting where appRoutingActivityVisible:
                policy.connections = true
                policy.appRoutingActivity = true
            case .connections:
                policy.traffic = true
                policy.connections = true
                policy.appRoutingActivity = true
            case .logs:
                policy.logs = true
            case .appRouting, .profiles, .rules, .providers, .attention, .settings:
                break
            }
            return policy
        }
    }

    private enum AppRoutingActivityMonitorMode: Equatable {
        case providerOnly
        case detailed
        case background
    }

    struct AppRoutingActivityPollCursor: Equatable, Sendable {
        private(set) var current: UInt64
        private(set) var floor: UInt64
        private(set) var droppedDelta: UInt64 = 0
        private(set) var requiresStateReset = false
        private var remainingPageCount = 8

        init(cursor: UInt64, acknowledgedDroppedBefore: UInt64 = 0) {
            current = cursor
            floor = max(cursor, acknowledgedDroppedBefore)
        }

        mutating func observe(droppedBefore: UInt64?) -> Bool {
            guard let droppedBefore else { return false }
            let coveredCursor = max(current, floor)
            guard coveredCursor < droppedBefore else { return false }
            let (sum, overflow) = droppedDelta.addingReportingOverflow(
                droppedBefore - coveredCursor
            )
            droppedDelta = overflow ? .max : sum
            floor = droppedBefore
            guard !requiresStateReset else { return false }
            requiresStateReset = true
            current = 0
            return true
        }

        mutating func advance(to cursor: UInt64) {
            current = cursor
        }

        mutating func consumePage() -> Bool {
            guard remainingPageCount > 0 else { return false }
            remainingPageCount -= 1
            return true
        }

        var committed: UInt64 { max(current, floor) }
    }

    enum SystemProxyState: Equatable {
        case off
        case enabling
        case on
        case disabling
        case failed(String)
    }

    enum NetworkCaptureState: Equatable {
        case off
        case waitingForConnection
        case enabling
        case awaitingUserApproval
        case on(revision: UInt64)
        case disabling
        case requiresReboot
        case failed(String)
    }

    enum LocalListenerKind: String, CaseIterable, Identifiable, Sendable {
        case mixed

        var id: Self { self }
    }

    enum LocalListenerSource: Equatable, Sendable {
        case profile
        case override
        case managedFallback
    }

    struct LocalListenerEndpoint: Identifiable, Equatable, Sendable {
        let kind: LocalListenerKind
        let host: String
        let port: Int
        let source: LocalListenerSource

        var id: LocalListenerKind { kind }
        var address: String { "\(host):\(port)" }
    }

    /// A user-facing entrance that is currently part of the active MClash
    /// configuration.  This is deliberately separate from the legacy
    /// `LocalListenerEndpoint` (which represents the single managed Mixed
    /// compatibility socket) so existing automation clients remain stable
    /// while the UI can present any number of HTTP/SOCKS/App Routing entries.
    enum ActiveEntranceKind: String, CaseIterable, Identifiable, Sendable {
        case http, socks5, appRouting, tun, mixed

        var id: Self { self }
    }

    struct ActiveEntranceEndpoint: Identifiable, Equatable, Sendable {
        let id: EntranceID
        let name: String
        let kind: ActiveEntranceKind
        let host: String?
        let port: Int?
        let enabled: Bool

        var address: String? {
            guard let host, let port else { return nil }
            return "\(host):\(port)"
        }
    }

    enum RuntimeSettingsApplyOutcome: Equatable, Sendable {
        case unchanged
        case saved
        case savedAndRestarted
    }

    enum RuntimeSettingsApplyState: Equatable, Sendable {
        case idle
        case validating
        case restarting
        case saving
        case completed(RuntimeSettingsApplyOutcome)
        case failed(String)
    }

    enum TrafficHistoryPersistenceChoice: Int, Equatable, Sendable {
        case undecided
        case sessionOnly
        case persistent
    }

    enum TrafficHistoryRuntimeState: Equatable, Sendable {
        case notConfigured
        case sessionOnly
        case loading
        case ready(lastUpdatedAt: Date?)
        case unavailable(String)
    }

    enum ProviderOperationKind: String, Hashable, Sendable {
        case updateProxy
        case healthCheckProxy
        case updateRule
    }

    struct ProviderOperationReceipt: Equatable, Sendable {
        enum Outcome: Equatable, Sendable {
            case succeeded
            case failed(String)
        }

        let kind: ProviderOperationKind
        let providerName: String
        let completedAt: Date
        let outcome: Outcome
    }

    struct SystemProxySettingsReceipt: Equatable, Sendable {
        enum Outcome: Equatable, Sendable {
            case savedForNextConnection
            case appliedAndVerified
            case rejectedAndRolledBack(String)
            case rollbackFailed(String)
        }

        let completedAt: Date
        let outcome: Outcome
    }

    struct ProfileBatchUpdateReceipt: Equatable, Sendable {
        let completedAt: Date
        let updatedCount: Int
        let unchangedCount: Int
        let failedCount: Int
    }

    struct NetworkCaptureChangeReceipt: Equatable, Sendable {
        enum Outcome: Equatable, Sendable {
            case savedForNextActivation
            case rulesUpdatedLive(dnsEnabled: Bool)
            case requiresReboot(dnsEnabled: Bool)
            case appliedAndVerified(
                enabled: Bool,
                dnsEnabled: Bool,
                systemProxyWasDisabled: Bool
            )
            case rejectedAndRolledBack(String)
            case rollbackFailed(String)
        }

        let completedAt: Date
        let duration: TimeInterval
        let outcome: Outcome
    }

    private enum ProfileRefreshOperationOutcome {
        case updated
        case unchanged
        case failed
    }

    enum Operation: Hashable {
        case connection
        case importProfile
        case addRemoteProfile
        case updateProfile(ProfileID)
        case activateProfile(ProfileID)
        case refreshProfile(ProfileID)
        case refreshAllProfiles
        case removeProfile(ProfileID)
        case changeRuntimeSettings
        case changeSystemProxySettings
        case changeApplicationSettings
        case exportBackup
        case restoreBackup
        case changeMode
        case changeSystemProxy
        case changeNetworkCapture
        case recoverNetworkEnvironment
        case selectProxy(String)
        case clearProxyOverride(String)
        case measureDelay(String)
        case measureGroupDelay(String)
        case refreshProfileProxyWorkspace(ProfileID)
        case changeProfileMode(ProfileID)
        case selectProfileProxy(ProfileID, String)
        case clearProfileProxyOverride(ProfileID, String)
        case measureProfileProxyDelay(ProfileID, String)
        case measureProfileGroupDelay(ProfileID, String)
        case refreshRules
        case refreshProviders
        case updateProxyProvider(String)
        case healthCheckProxyProvider(String)
        case updateRuleProvider(String)
        case closeConnection(String)
        case closeAllConnections
    }

    enum Destination: String, CaseIterable, Identifiable {
        case overview
        case workspaces
        case nodes
        case sources
        case entrances
        case dns
        case proxies
        case proxyGroups
        case appRouting
        case profiles
        case rules
        case providers
        case connections
        case attention
        case logs
        case settings

        var id: Self { self }

        var title: String {
            switch self {
            case .overview: "Overview"
            case .workspaces: "Configuration"
            case .nodes: "Nodes"
            case .sources: "Sources"
            case .entrances: "Entrances"
            case .dns: "DNS"
            case .proxies: "Node Groups"
            case .proxyGroups: "Node Groups"
            case .appRouting: "App Routing"
            case .profiles: "Profiles"
            case .rules: "Rules"
            case .providers: "Providers"
            case .connections: "Traffic"
            case .attention: "Attention"
            case .logs: "Logs"
            case .settings: "Settings"
            }
        }

        var symbol: String {
            switch self {
            case .overview: "gauge.with.dots.needle.50percent"
            case .workspaces: "rectangle.3.group"
            case .nodes: "point.3.connected.trianglepath.dotted"
            case .sources: "arrow.down.circle"
            case .entrances: "arrow.triangle.branch"
            case .dns: "network"
            case .proxies: "square.3.layers.3d"
            case .proxyGroups: "rectangle.3.group"
            case .appRouting: "app.badge"
            case .profiles: "doc.text"
            case .rules: "list.bullet.rectangle"
            case .providers: "shippingbox"
            case .connections: "arrow.left.arrow.right"
            case .attention: "exclamationmark.triangle"
            case .logs: "text.alignleft"
            case .settings: "gearshape"
            }
        }
    }

    var selection: Destination? = .overview {
        didSet {
            guard selection != oldValue else { return }
            presentationDemandDidChange()
        }
    }
    private(set) var mainWindowIsVisible = false
    private(set) var mainWindowPresentationTelemetryIsVisible = false
    private(set) var menuBarContentIsVisible = false
    private(set) var appRoutingActivityViewIsVisible = false
    var coreState: CoreRunState = .stopped
    var activeConfigURL: URL?
    var logs: [CoreLogLine] = []
    var errorMessage: String?
    var profiles: [ProfileMetadata] = []
    /// Authoritative MClash strategy document. Legacy Profiles remain available
    /// as source snapshots while this document owns groups, rules, DNS and
    /// entrances for the new configuration workbench.
    private(set) var configurationRevision = UUID()
    private(set) var configurationDocument: ConfigurationDocument = .empty {
        didSet {
            guard configurationDocument != oldValue else { return }
            configurationRevision = UUID()
        }
    }
    private(set) var compiledConfiguration: CompiledConfiguration?
    private(set) var configurationDiagnostics: [ConfigurationDiagnostic] = []
    /// Whether the selected MClash Workspace is authoritative for the next
    /// activation. Populated installs are adopted automatically once during
    /// the node-only configuration migration; the legacy path remains only as
    /// an explicit recovery fallback.
    var unifiedConfigurationEnabled: Bool {
        didSet { preferenceDefaults.set(unifiedConfigurationEnabled, forKey: Self.unifiedConfigurationEnabledKey) }
    }
    private(set) var profileBatchUpdateReceipt: ProfileBatchUpdateReceipt?
    var activeProfileID: ProfileID?
    private(set) var profileRuntimePlan: ProfileRuntimePlan = .empty
    private(set) var auxiliaryCoreStates: [ProfileID: CoreRunState] = [:]
    var runtimeConfig: MihomoConfig?
    private(set) var runtimeOverrides: RuntimeOverrides = .empty
    private(set) var activeProfileListenerPorts = RuntimePortOverrides()
    private(set) var runtimeSettingsApplyState: RuntimeSettingsApplyState = .idle
    var proxyGroups: [MihomoProxy] = []
    var proxiesByName: [String: MihomoProxy] = [:]
    var proxyTopology: ProxyTopology = .empty
    var proxySelectionPaths: [String: ProxySelectionPath] = [:]
    var proxyDelays: [String: Int] = [:]
    /// Controller-backed Proxies workspaces keyed by the real Profile ID.
    /// These never replace or alias the legacy app-wide proxy properties above.
    private(set) var profileProxyWorkspaceStates:
        [ProfileID: ProfileProxyWorkspaceState] = [:]
    private(set) var pendingProfileProxySelections:
        [ProfileProxySelectionKey: String] = [:]
    var rules: [MihomoRule] = [] {
        didSet {
            rulesUseGlobalProxy = rules.contains { $0.proxy == "GLOBAL" }
            updateGlobalProxyGroupRelevance()
        }
    }
    private(set) var rulesLastLoadedAt: Date?
    var proxyProviders: [MihomoProxyProvider] = []
    var ruleProviders: [MihomoRuleProvider] = []
    private(set) var providersLastLoadedAt: Date?
    private(set) var providerOperationReceipts: [String: ProviderOperationReceipt] = [:]
    var rulesErrorMessage: String?
    var providersErrorMessage: String?
    var traffic = MihomoTraffic(upload: 0, download: 0, uploadTotal: 0, downloadTotal: 0)
    var trafficHistory: [TrafficSample] = []
    var connections: MihomoConnectionSnapshot? {
        didSet {
            connectionPresentationRevision &+= 1
            let recordedClosures = recordClosedConnections(
                previous: oldValue,
                current: connections
            )
            if presentationTelemetryPolicy.appRoutingActivity {
                scheduleFlowLedgerRefresh()
            }
            if recordedClosures {
                scheduleFlowLedgerRefresh(neededForAccounting: true)
            }
            if presentationTelemetryPolicy.connections {
                proxyInspectorTrafficRevision &+= 1
                connectionsUseGlobalProxy = connections?.connections.contains {
                    $0.chains.contains("GLOBAL")
                } == true
                updateGlobalProxyGroupRelevance()
            }
        }
    }
    private(set) var connectionPresentationRevision: UInt64 = 0
    private(set) var recentlyClosedConnections: [ClosedConnectionRecord] = []
    private(set) var flowLedger = FlowLedger(activeConnections: [])
    private(set) var appRoutingFlowEntries: [UUID: FlowLedgerEntry] = [:] {
        didSet {
            appRoutingActivityPresentationRevision &+= 1
        }
    }
    var routeTrafficEntries: [TrafficAttribution.Entry] = [] {
        didSet {
            proxyInspectorTrafficRevision &+= 1
        }
    }
    private(set) var proxyInspectorTrafficRevision: UInt64 = 0
    private(set) var globalProxyGroupIsRelevant = false
    var systemProxyState: SystemProxyState = .off
    /// Read-only observation of macOS proxy state. This is intentionally
    /// separate from `systemProxyState`: a previous MClash process (or another
    /// app) may have left proxy settings enabled without a recoverable MClash
    /// snapshot. We must report that fact without claiming ownership.
    private(set) var systemProxyObservedEnabled = false
    private(set) var systemProxyObservedMatchesMClash = false
    private(set) var systemProxyObservedAt: Date?
    private(set) var systemProxyPreferences: SystemProxyPreferences = .defaults
    private(set) var networkCaptureState: NetworkCaptureState = .off
    private(set) var networkCapturePreferences = NetworkCapturePreferences.defaults()
    private(set) var appRoutingActivities: [AppRoutingActivity] = [] {
        didSet {
            appRoutingActivityStateRevision &+= 1
            appRoutingActivityPresentationRevision &+= 1
        }
    }
    private var appRoutingActivityStateRevision: UInt64 = 0
    private(set) var appRoutingActivityPresentationRevision: UInt64 = 0
    private(set) var appRoutingActiveCount = 0
    private(set) var appRoutingRuleStatistics: [String: AppRoutingRuleStatistics] = [:]
    private(set) var appRoutingActivityError: String?
    private(set) var appRoutingTrafficRates: AppRoutingTrafficRateSnapshot = .zero
    private(set) var appRoutingActivityDroppedCount: UInt64 = 0
    private(set) var appRoutingActivityCoverageStartedAt: Date?
    private(set) var dnsProxyRuntimeStatus: DNSProxyRuntimeStatus?
    private(set) var dnsProxyRuntimeError: String?
    private(set) var dnsProxyLastVerifiedAt: Date?
    private(set) var dnsProxyAutomaticallyDisabled = false
    private(set) var networkCaptureChangeReceipt: NetworkCaptureChangeReceipt?
    private(set) var networkCaptureRollbackFailure: String?
    private var dnsProxyRuntimeFailureCount = 0
    private(set) var launchAtLogin = false
    private(set) var launchAtLoginRequiresApproval = false
    private(set) var notificationsEnabled = false
    var openAtLoginSilently: Bool {
        didSet {
            preferenceDefaults.set(
                openAtLoginSilently,
                forKey: Self.openAtLoginSilentlyKey
            )
        }
    }
    var lightweightMode: Bool {
        didSet {
            if lightweightMode {
                menuBarContentIsVisible = false
            }
            preferenceDefaults.set(lightweightMode, forKey: Self.lightweightModeKey)
            presentationDemandDidChange()
        }
    }
    var controllerState: ControllerState = .idle
    private(set) var pendingSubscriptionImport: SubscriptionImportRequest?
    private(set) var pendingMode: String?
    private(set) var pendingSystemProxyEnabled: Bool?
    private(set) var pendingNetworkCaptureEnabled: Bool?
    private(set) var pendingProxySelections: [String: String] = [:]
    var autoConnectOnLaunch: Bool {
        didSet {
            preferenceDefaults.set(autoConnectOnLaunch, forKey: Self.autoConnectOnLaunchKey)
        }
    }
    private(set) var connectionDesiredOnLaunch: Bool
    var autoEnableSystemProxy: Bool {
        didSet {
            preferenceDefaults.set(autoEnableSystemProxy, forKey: Self.autoEnableSystemProxyKey)
        }
    }
    var menuBarDisplayStyle: MenuBarDisplayStyle {
        didSet {
            preferenceDefaults.set(
                menuBarDisplayStyle.rawValue,
                forKey: Self.menuBarDisplayStyleKey
            )
            presentationDemandDidChange()
        }
    }
    private(set) var pinnedQuickRouteNames: [String]
    var closeConnectionsOnRoutingChange: Bool {
        didSet {
            preferenceDefaults.set(
                closeConnectionsOnRoutingChange,
                forKey: Self.closeConnectionsOnRoutingChangeKey
            )
        }
    }
    var trafficHistoryPersistenceChoice: TrafficHistoryPersistenceChoice {
        didSet {
            preferenceDefaults.set(
                trafficHistoryPersistenceChoice.rawValue,
                forKey: Self.trafficHistoryPersistenceChoiceKey
            )
        }
    }
    private(set) var trafficHistoryRuntimeState: TrafficHistoryRuntimeState = .notConfigured
    private(set) var trafficHistoryRetention: TrafficHistoryRetention = .default
    private(set) var trafficHistoryTodaySnapshot: TrafficHistorySnapshot?
    private(set) var trafficHistoryWeekSnapshot: TrafficHistorySnapshot?
    private(set) var degradedStreams: Set<LiveStream> = []
    private(set) var liveStreamHealth: [LiveStream: LiveStreamHealth] = Dictionary(
        uniqueKeysWithValues: LiveStream.allCases.map { ($0, .inactive) }
    )
    private(set) var operations: Set<Operation> = []
    private(set) var storageInitializationFailures: [StorageInitializationFailure] = []
    private(set) var systemProxyGuardFailure: SystemProxyGuardFailure?
    private(set) var systemProxyGuardLastVerifiedAt: Date?
    private(set) var systemProxyGuardLastRepairedAt: Date?
    private(set) var systemProxyGuardRepairCount = 0
    private(set) var systemProxySettingsReceipt: SystemProxySettingsReceipt?

    private let supervisor: CoreSupervisor
    private let coreFleet: CoreFleetSupervisor
    private let binaryLocator: CoreBinaryLocator
    private let secretStore: any CoreSecretProviding
    private let profileStore: ProfileStore?
    private let profileLayout: ProfileDirectoryLayout?
    private let profileRuntimePlanStore: ProfileRuntimePlanStore?
    private let configurationStore: ConfigurationStore?
    private let runtimeOverrideCoordinator: RuntimeOverrideActivationCoordinator?
    private let systemProxyPreferencesStore: SystemProxyPreferencesStore?
    private let networkCaptureConfigurationStore: NetworkCaptureConfigurationStore?
    private let networkExtensionControl: any NetworkExtensionControlling
    private let networkEnvironmentMonitor: any NetworkEnvironmentMonitoring
    private let systemProxyManager: SystemProxyManager
    private let localPortProbe: LocalPortProbe
    private let geoDataInstaller: BundledGeoDataInstaller
    private let preferenceDefaults: UserDefaults
    private let profileProxyControllerResolverOverride:
        ProfileProxyControllerResolver?
    private let profileBackupService = ProfileBackupService()
    private let notificationCenter = AppNotificationCenter()
    private var managedMixedPort: Int?
    /// Exact Profile/port pairs verified through that Core's authenticated
    /// controller during this host process. A raw TCP bind can remain
    /// unavailable after shutdown because of TIME_WAIT, but ownership must
    /// never transfer between Profiles or unverified launch attempts.
    private var verifiedMClashMixedPorts: [ProfileID: Set<Int>] = [:]
    private var networkExtensionMihomoListener: NetworkExtensionMihomoListenerConfiguration?
    private var networkExtensionProfileListeners:
        [ProfileID: NetworkExtensionMihomoListenerConfiguration] = [:]
    private var auxiliaryLaunchConfigurations: [ProfileID: CoreLaunchConfiguration] = [:]
    private var rulesUseGlobalProxy = false
    private var connectionsUseGlobalProxy = false
    private var apiClient: MihomoAPIClient?
    private var activeControllerEndpoint: URL?
    private var controllerSetupOperation: (id: UUID, endpoint: URL, task: Task<Void, Never>)?
    private var eventTask: Task<Void, Never>?
    private var coreFleetEventTask: Task<Void, Never>?
    private var trafficTask: Task<Void, Never>?
    private var connectionsTask: Task<Void, Never>?
    private var connectionStreamIntervalMilliseconds: Int?
    private var apiLogTask: Task<Void, Never>?
    private var pendingCoreLogs: [CoreLogLine] = []
    private var coreLogFlushTask: Task<Void, Never>?
    private var proxyRefreshTask: Task<Void, Never>?
    private var liveFreshnessWatchdogTask: Task<Void, Never>?
    private var subscriptionUpdateTask: Task<Void, Never>?
    private var controllerGeneration = 0
    private var proxyRefreshRevision = 0
    private var proxyTopologyInput: ProxyTopologyInput?
    private var systemProxyEnableOperation: (id: UUID, task: Task<Void, Never>)?
    private var systemProxyRestoreOperation: (id: UUID, task: Task<Bool, Never>)?
    private var systemProxyGuardTask: Task<Void, Never>?
    private var crashProxyRestoreOperation: (id: UUID, task: Task<Bool, Never>)?
    private var shouldReenableSystemProxyAfterCrash = false
    private var configurationActivationRecoveryRequiresSystemProxy = false
    private var contextualProxyDelays: [ProxyDelayContextKey: Int] = [:]
    private var proxyProfileStructure: ProfileStructure = .empty
    private var profileProxyMeasuredDelays: [ProfileID: [String: Int]] = [:]
    private var profileProxyWorkspaceRevisions: [ProfileID: UInt64] = [:]
    private var trafficAttribution = TrafficAttribution()
    private var persistentTrafficHistoryStore: TrafficHistoryStore?
    private var trafficHistoryPersistTask: Task<Void, Never>?
    private var trafficHistoryPersistDrainTask: Task<Void, Never>?
    private var trafficHistoryPersistDrainGeneration: UInt64?
    private var trafficHistoryPersistGeneration: UInt64 = 0
    private var trafficHistoryPersistenceOperationGeneration: UInt64 = 0
    private var trafficHistoryLastPrunedAt: Date?
    private var trafficHistoryClearInProgress = false
    private var trafficHistoryPersistenceTransitionInProgress = false
    private var trafficHistoryMutationInProgress = false
    private var trafficHistoryMutationWaiters: [CheckedContinuation<Void, Never>] = []
    private var queuedTrafficHistoryCompletions: [TrafficHistoryCompletedFlow] = []
    private var queuedTrafficHistoryIdentifiers: Set<String> = []
    private var persistedTrafficHistoryIdentifiers: Set<String> = []
    private var persistedTrafficHistoryIdentifierOrder: [String] = []
    private var flowLedgerRevision: UInt64 = 0
    private var flowLedgerTask: Task<Void, Never>?
    private var flowLedgerTaskGeneration: UInt64 = 0
    private var flowLedgerPresentationRefreshPending = false
    private var flowLedgerAccountingRefreshPending = false
    private var flowLedgerActiveBuildNeedsAccounting = false
    private var prepared = false
    private var preparationOperation: (id: UUID, task: Task<Void, Never>)?
    private var networkCaptureActivationOperation: (id: UUID, task: Task<Void, Never>)?
    private var networkCaptureDeactivationOperation: (id: UUID, task: Task<Bool, Never>)?
    private var appRoutingActivityTask: Task<Void, Never>?
    private var appRoutingActivityMonitorMode: AppRoutingActivityMonitorMode?
    private var appRoutingMonitorGeneration: UInt64 = 0
    private var appRoutingMonitorsPausedForSleep = false
    private var appRoutingActivityAcknowledgedDroppedBefore: UInt64 = 0
    private var dnsProxyRuntimeTask: Task<Void, Never>?
    private var dnsProxyMonitorGeneration: UInt64 = 0
    private var networkEnvironmentEventTask: Task<Void, Never>?
    private var networkEnvironmentDebounceTask: Task<Void, Never>?
    private var networkEnvironmentRecoveryTask: Task<Void, Never>?
    private var networkEnvironmentRecoveryPolicy = NetworkEnvironmentRecoveryPolicy()
    private var networkEnvironmentPathIsUsable: Bool?
    private var networkEnvironmentRecoveryArmed = false
    private var networkEnvironmentDebounceGeneration: UInt64 = 0
    private var networkEnvironmentRecoveryGeneration: UInt64 = 0
    private var appRoutingActivityCursor: UInt64 = 0
    private var appRoutingActivitiesByIdentifier: [UUID: AppRoutingActivity] = [:]
    private var appRoutingTrafficRateTracker = AppRoutingTrafficRateTracker()
    private var networkExtensionPreferencesCheckGeneration: UInt64 = 0
    private var appRoutingProviderPreferencesCheckDeadline: ContinuousClock.Instant?
    private var dnsProxyPreferencesCheckDeadline: ContinuousClock.Instant?
    private(set) var appRoutingProviderStatusFailureCount = 0
    private(set) var appRoutingProviderLastVerifiedAt: Date?
    private(set) var preparationInProgress = false
    private var shutdownInProgress = false
    private var startupPreparationErrorMessage: String?
    private let testInstance: Bool

    init(
        supervisor: CoreSupervisor = CoreSupervisor(),
        binaryLocator: CoreBinaryLocator = CoreBinaryLocator(),
        secretStore: any CoreSecretProviding = EphemeralCoreSecretProvider(),
        systemProxyManager: SystemProxyManager = SystemProxyManager(),
        localPortProbe: LocalPortProbe = LocalPortProbe(),
        profileDirectoryLayout: ProfileDirectoryLayout? = nil,
        profileStoreOverride: ProfileStore? = nil,
        geoDataInstaller: BundledGeoDataInstaller = .applicationBundle(),
        preferenceDefaults: UserDefaults? = nil,
        networkExtensionControl: (any NetworkExtensionControlling)? = nil,
        networkEnvironmentMonitor: (any NetworkEnvironmentMonitoring)? = nil,
        profileProxyControllerResolver: ProfileProxyControllerResolver? = nil
    ) {
        self.supervisor = supervisor
        coreFleet = CoreFleetSupervisor()
        self.binaryLocator = binaryLocator
        self.secretStore = secretStore
        self.systemProxyManager = systemProxyManager
        self.localPortProbe = localPortProbe
        self.geoDataInstaller = geoDataInstaller
        profileProxyControllerResolverOverride = profileProxyControllerResolver
        let environment = ProcessInfo.processInfo.environment
        testInstance = environment["MCLASH_TEST_MODE"] == "1"
            || CommandLine.arguments.contains("--mclash-test-instance")
        let defaults: UserDefaults
        if let preferenceDefaults {
            defaults = preferenceDefaults
        } else if testInstance {
            let namespace = ProcessInfo.processInfo.environment[
                "MCLASH_INSTANCE_NAMESPACE"
            ] ?? "isolated"
            defaults = UserDefaults(
                suiteName: "one.leaper.mclash.\(namespace)"
            ) ?? .standard
        } else {
            defaults = .standard
        }
        self.preferenceDefaults = defaults
        self.networkExtensionControl = networkExtensionControl
            ?? (testInstance
                ? NetworkExtensionControlService.inert()
                : NetworkExtensionControlService.live())
        if let networkEnvironmentMonitor {
            self.networkEnvironmentMonitor = networkEnvironmentMonitor
        } else {
            self.networkEnvironmentMonitor = AppleNetworkEnvironmentMonitor()
        }
        if defaults.object(forKey: Self.trafficHistoryPersistenceChoiceKey) == nil {
            trafficHistoryPersistenceChoice = .undecided
        } else {
            trafficHistoryPersistenceChoice = TrafficHistoryPersistenceChoice(
                rawValue: defaults.integer(
                    forKey: Self.trafficHistoryPersistenceChoiceKey
                )
            ) ?? .undecided
        }
        if defaults.object(forKey: Self.autoConnectOnLaunchKey) == nil {
            autoConnectOnLaunch = true
        } else {
            autoConnectOnLaunch = defaults.bool(forKey: Self.autoConnectOnLaunchKey)
        }
        if defaults.object(forKey: Self.connectionDesiredOnLaunchKey) == nil {
            // Preserve the pre-1.3 startup behavior on upgrade. Subsequent
            // explicit Connect/Disconnect actions make this an exact last
            // user intent instead of an unconditional reconnect.
            connectionDesiredOnLaunch = true
        } else {
            connectionDesiredOnLaunch = defaults.bool(
                forKey: Self.connectionDesiredOnLaunchKey
            )
        }
        if defaults.object(forKey: Self.autoEnableSystemProxyKey) == nil {
            autoEnableSystemProxy = true
        } else {
            autoEnableSystemProxy = defaults.bool(forKey: Self.autoEnableSystemProxyKey)
        }
        menuBarDisplayStyle = defaults.string(
            forKey: Self.menuBarDisplayStyleKey
        )
        .flatMap(MenuBarDisplayStyle.init(rawValue:)) ?? .logo
        pinnedQuickRouteNames = Self.normalizedQuickRouteNames(
            defaults.stringArray(forKey: Self.pinnedQuickRouteNamesKey) ?? []
        )
        if defaults.object(forKey: Self.closeConnectionsOnRoutingChangeKey) == nil {
            closeConnectionsOnRoutingChange = true
        } else {
            closeConnectionsOnRoutingChange = defaults.bool(
                forKey: Self.closeConnectionsOnRoutingChangeKey
            )
        }
        notificationsEnabled = defaults.bool(forKey: Self.notificationsEnabledKey)
        if defaults.object(forKey: Self.openAtLoginSilentlyKey) == nil {
            openAtLoginSilently = true
        } else {
            openAtLoginSilently = defaults.bool(
                forKey: Self.openAtLoginSilentlyKey
            )
        }
        lightweightMode = defaults.bool(forKey: Self.lightweightModeKey)
        if testInstance {
            autoConnectOnLaunch = true
            connectionDesiredOnLaunch = true
            autoEnableSystemProxy = false
            unifiedConfigurationEnabled = true
        } else if defaults.object(forKey: Self.unifiedConfigurationEnabledKey) == nil {
            unifiedConfigurationEnabled = false
        } else {
            unifiedConfigurationEnabled = defaults.bool(
                forKey: Self.unifiedConfigurationEnabledKey
            )
        }
        if testInstance {
            launchAtLogin = false
            launchAtLoginRequiresApproval = false
        } else {
            let loginItemManager = LoginItemManager()
            launchAtLogin = loginItemManager.isEnabled
            launchAtLoginRequiresApproval = loginItemManager.requiresApproval
        }

        var initializationFailures: [StorageInitializationFailure] = []
        let layout: ProfileDirectoryLayout?
        if let profileDirectoryLayout {
            layout = profileDirectoryLayout
        } else {
            do {
                layout = try ProfileDirectoryLayout.applicationSupport()
            } catch {
                layout = nil
                initializationFailures.append(
                    StorageInitializationFailure(
                        component: .applicationState,
                        occurredAt: Date(),
                        reason: error.localizedDescription,
                        recoverySuggestion: AppLocalization.string(
                            "Restore access to the user Application Support folder, then relaunch MClash."
                        )
                    )
                )
            }
        }

        profileLayout = layout
        if let layout {
            do {
                profileRuntimePlanStore = try ProfileRuntimePlanStore(layout: layout)
            } catch {
                profileRuntimePlanStore = nil
                initializationFailures.append(
                    StorageInitializationFailure(
                        component: .applicationState,
                        occurredAt: Date(),
                        reason: error.localizedDescription,
                        recoverySuggestion: AppLocalization.string(
                            "Restore read and write access to the MClash State folder, then relaunch MClash."
                        )
                    )
                )
            }
            if let profileStoreOverride {
                profileStore = profileStoreOverride
            } else {
                do {
                    profileStore = try ProfileStore(layout: layout)
                } catch {
                    profileStore = nil
                    initializationFailures.append(
                        StorageInitializationFailure(
                            component: .profiles,
                            occurredAt: Date(),
                            reason: error.localizedDescription,
                            recoverySuggestion: AppLocalization.format(
                                "Restore read and write access to %@, then relaunch MClash.",
                                layout.profilesDirectory.path
                            )
                        )
                    )
                }
            }

            do {
                configurationStore = try ConfigurationStore(layout: layout)
            } catch {
                configurationStore = nil
                initializationFailures.append(
                    StorageInitializationFailure(
                        component: .configuration,
                        occurredAt: Date(),
                        reason: error.localizedDescription,
                        recoverySuggestion: AppLocalization.format(
                            "Restore read and write access to %@, then relaunch MClash.",
                            layout.configurationDirectory.path
                        )
                    )
                )
            }

            do {
                let overrideStore = try RuntimeOverrideStore(profileLayout: layout)
                runtimeOverrideCoordinator = RuntimeOverrideActivationCoordinator(
                    overrideStore: overrideStore
                )
            } catch {
                runtimeOverrideCoordinator = nil
                initializationFailures.append(
                    StorageInitializationFailure(
                        component: .runtimeOverrides,
                        occurredAt: Date(),
                        reason: error.localizedDescription,
                        recoverySuggestion: AppLocalization.string(
                            "Restore read and write access to the MClash Settings folder, then relaunch MClash."
                        )
                    )
                )
            }

            do {
                systemProxyPreferencesStore = try SystemProxyPreferencesStore(
                    profileLayout: layout
                )
            } catch {
                systemProxyPreferencesStore = nil
                initializationFailures.append(
                    StorageInitializationFailure(
                        component: .systemProxySettings,
                        occurredAt: Date(),
                        reason: error.localizedDescription,
                        recoverySuggestion: AppLocalization.string(
                            "Restore read and write access to the MClash Settings folder, then relaunch MClash."
                        )
                    )
                )
            }

            do {
                networkCaptureConfigurationStore = try NetworkCaptureConfigurationStore(
                    profileLayout: layout
                )
            } catch {
                networkCaptureConfigurationStore = nil
                initializationFailures.append(
                    StorageInitializationFailure(
                        component: .appRoutingSettings,
                        occurredAt: Date(),
                        reason: error.localizedDescription,
                        recoverySuggestion: AppLocalization.string(
                            "Restore read and write access to the MClash Settings folder, then relaunch MClash."
                        )
                    )
                )
            }
        } else {
            profileStore = nil
            profileRuntimePlanStore = nil
            runtimeOverrideCoordinator = nil
            systemProxyPreferencesStore = nil
            networkCaptureConfigurationStore = nil
            configurationStore = nil
        }
        storageInitializationFailures = initializationFailures

        eventTask = Task { [weak self, events = supervisor.events] in
            for await event in events {
                guard !Task.isCancelled else { break }
                self?.receive(event)
            }
        }
        coreFleetEventTask = Task { [weak self, events = coreFleet.events] in
            for await event in events {
                guard !Task.isCancelled else { break }
                self?.receive(event)
            }
        }
    }

    func prepare() async {
        guard !prepared, !shutdownInProgress else { return }
        if let preparationOperation {
            await preparationOperation.task.value
            return
        }

        let id = UUID()
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performStartupPreparation()
        }
        preparationOperation = (id, task)
        await task.value
        if preparationOperation?.id == id {
            preparationOperation = nil
        }
    }

    private func performStartupPreparation() async {
        guard !prepared else { return }
        preparationInProgress = true
        defer { preparationInProgress = false }

        var startupUnifiedMigrationPending = false
        var startupUnifiedMigrationActivated = false
        var startupUnifiedMigrationPreviousProfileID: ProfileID?
        var startupUnifiedMigrationPreviousDocument: ConfigurationDocument?
        var startupUnifiedMigrationPreviousNetworkCapturePreferences: NetworkCapturePreferences?
        do {
            if !testInstance {
                try LoginItemManager().migrateLegacyRegistrationIfNeeded()
                let loginItemManager = LoginItemManager()
                launchAtLogin = loginItemManager.isEnabled
                launchAtLoginRequiresApproval = loginItemManager.requiresApproval
            }
        } catch {
            appendSupervisorLog(
                "Launch at Login could not be migrated to the system main-app registration: \(error.localizedDescription)"
            )
        }
        await prepareTrafficHistoryPersistenceIfNeeded()

        do {
            try Task.checkCancellation()
            guard !shutdownInProgress else { return }
            if let profileStore, let profileLayout {
                if let runtimeOverrideCoordinator {
                    do {
                        runtimeOverrides = try await runtimeOverrideCoordinator.overrides()
                        clearStorageFailure(for: .runtimeOverrides)
                    } catch {
                        recordStorageFailure(
                            component: .runtimeOverrides,
                            error: error,
                            recoverySuggestion: AppLocalization.string(
                                "Restore or remove the invalid runtime settings document, then relaunch MClash."
                            )
                        )
                        throw error
                    }
                }
                if let systemProxyPreferencesStore {
                    do {
                        systemProxyPreferences = try await systemProxyPreferencesStore.load()
                        clearStorageFailure(for: .systemProxySettings)
                    } catch {
                        recordStorageFailure(
                            component: .systemProxySettings,
                            error: error,
                            recoverySuggestion: AppLocalization.string(
                                "Restore or remove the invalid system proxy settings document, then relaunch MClash."
                            )
                        )
                        throw error
                    }
                }
                if let networkCaptureConfigurationStore {
                    do {
                        networkCapturePreferences = try await networkCaptureConfigurationStore.load()
                        clearStorageFailure(for: .appRoutingSettings)
                    } catch {
                        recordStorageFailure(
                            component: .appRoutingSettings,
                            error: error,
                            recoverySuggestion: AppLocalization.string(
                                "Restore or remove the invalid App Routing settings document, then relaunch MClash."
                            )
                        )
                        throw error
                    }
                }
                do {
                    profiles = try await profileStore.profiles()
                    activeProfileID = try await profileStore.activeProfileID()
                    clearStorageFailure(for: .profiles)
                } catch {
                    recordStorageFailure(
                        component: .profiles,
                        error: error,
                        recoverySuggestion: AppLocalization.string(
                            "Restore read access to the Profiles and State folders, then relaunch MClash."
                        )
                    )
                    throw error
                }
                if let configurationStore {
                    do {
                        let recovery = try await configurationStore.loadRecoveringInvalidDocument()
                        if recovery.quarantinedURL != nil {
                            appendSupervisorLog(
                                AppLocalization.string(
                                    "The MClash configuration document was invalid and was quarantined; a clean strategy document was created."
                                )
                            )
                        }
                        configurationDocument = recovery.document == .empty
                            ? .mclashDefault()
                            : recovery.document
                        configurationDiagnostics = allConfigurationDiagnostics(for: configurationDocument)
                        if recovery.document == .empty {
                            try await configurationStore.save(configurationDocument)
                        }
                        clearStorageFailure(for: .configuration)
                    } catch {
                        recordStorageFailure(
                            component: .configuration,
                            error: error,
                            recoverySuggestion: AppLocalization.string(
                                "Restore or remove the invalid Configuration document, then relaunch MClash."
                            )
                        )
                        throw error
                    }
                }
                try await recoverInterruptedConfigurationActivationIfNeeded()
                // Observe (never modify) the host proxy before any profile or
                // runtime migration. This catches settings left by an older
                // MClash build or another utility even when no core is ready
                // yet, so the overview can explain the real network path.
                await refreshSystemProxyObservation()
                await synchronizeConfigurationSources()
                startupUnifiedMigrationPending =
                    shouldAutomaticallyMigrateToUnifiedConfiguration()
                if startupUnifiedMigrationPending {
                    startupUnifiedMigrationPreviousProfileID = activeProfileID
                    startupUnifiedMigrationPreviousDocument = configurationDocument
                    startupUnifiedMigrationPreviousNetworkCapturePreferences = networkCapturePreferences
                    try await prepareDocumentForUnifiedMigration()
                }
                if startupUnifiedMigrationPending || unifiedConfigurationEnabled {
                    do {
                        let compiled = try compileConfiguration()
                        compiledConfiguration = compiled
                        try await synchronizeCompiledCaptureState(compiled)
                        if startupUnifiedMigrationPending {
                            unifiedConfigurationEnabled = true
                        }
                    } catch {
                        if startupUnifiedMigrationPending {
                            unifiedConfigurationEnabled = false
                            compiledConfiguration = nil
                            appendSupervisorLog(
                                AppLocalization.format(
                                    "MClash could not adopt the unified configuration during upgrade: %@",
                                    error.localizedDescription
                                )
                            )
                        }
                        throw error
                    }
                }
                if startupUnifiedMigrationPending, activeProfileID == nil {
                    guard let firstProfileID = profiles.first?.id else {
                        throw AppModelError.profileStoreUnavailable
                    }
                    activeProfileID = firstProfileID
                    await refreshActiveProfileListenerPorts()
                }
                if activeProfileID != nil {
                    // A restarted host has no trustworthy in-memory provider
                    // state, including when the last host process crashed
                    // between persisting "disabled" and stopping the provider.
                    // Quiesce persisted managers before allocating new core
                    // ports or listener credentials.
                    try await networkExtensionControl.disable()
                    networkCaptureState = .off
                }
                await refreshActiveProfileListenerPorts()
                try await loadProfileRuntimePlan()
                try await repairManagedMixedPortCollision()
                try await prepareProfileRoutingSessions(
                    for: networkCapturePreferences.enabled
                        ? networkCapturePreferences.snapshot.rules
                        : [],
                    startAuxiliary: false
                )
                if let activeProfileID {
                    if runtimeOverrideCoordinator != nil {
                        let activation = try await activateStoredProfile(
                            activeProfileID,
                            validator: try makeProfileValidator()
                        )
                        activeConfigURL = activation.configurationURL
                        if !unifiedConfigurationMigrationCompleted,
                           !configurationDocument.nodes.isEmpty {
                            startupUnifiedMigrationActivated = true
                            markUnifiedConfigurationMigrationCompleted()
                            appendSupervisorLog(
                                AppLocalization.string(
                                    "The upgraded installation now uses the MClash unified configuration."
                                )
                            )
                        }
                    } else if unifiedConfigurationEnabled {
                        throw AppModelError.profileStoreUnavailable
                    } else if FileManager.default.fileExists(
                        atPath: profileLayout.runtimeConfigurationURL.path
                    ) {
                        activeConfigURL = profileLayout.runtimeConfigurationURL
                    }
                }

                try Task.checkCancellation()
                guard !shutdownInProgress else { return }
                let snapshotURL = systemProxySnapshotURL(layout: profileLayout)
                if FileManager.default.fileExists(atPath: snapshotURL.path) {
                    guard await performDisableSystemProxy() else {
                        await cleanupFailedConnectionAttempt()
                        // The restore operation already published the precise backend
                        // failure. Keep it visible and do not retry automatically in
                        // this launch, which could create an authorization loop.
                        startupPreparationErrorMessage = nil
                        prepared = true
                        return
                    }
                    appendSupervisorLog("Recovered system proxy settings left by an interrupted session.")
                }
            }
            try Task.checkCancellation()
            guard !shutdownInProgress else { return }
            if errorMessage == startupPreparationErrorMessage {
                errorMessage = nil
            }
            startupPreparationErrorMessage = nil
            await connectActiveProfileAtLaunchIfAvailable()
            if networkCapturePreferences.enabled, networkCaptureState == .off {
                networkCaptureState = .waitingForConnection
            }
            try Task.checkCancellation()
            guard !shutdownInProgress else { return }
            prepared = true
            startSubscriptionUpdateScheduler()
            startNetworkEnvironmentMonitoring()
        } catch is CancellationError {
            await cleanupFailedConnectionAttempt()
            return
        } catch {
            await cleanupFailedConnectionAttempt()
            if startupUnifiedMigrationPending && !startupUnifiedMigrationActivated {
                unifiedConfigurationEnabled = false
                compiledConfiguration = nil
                activeProfileID = startupUnifiedMigrationPreviousProfileID
                await refreshActiveProfileListenerPorts()
                if let previousDocument = startupUnifiedMigrationPreviousDocument {
                    configurationDocument = previousDocument
                    configurationDiagnostics = allConfigurationDiagnostics(
                        for: previousDocument
                    )
                    try? await configurationStore?.save(previousDocument)
                }
                if let previousPreferences = startupUnifiedMigrationPreviousNetworkCapturePreferences,
                   let captureStore = networkCaptureConfigurationStore {
                    do {
                        let durablePreferences = try await captureStore.load()
                        if durablePreferences != previousPreferences {
                            // replaceRules allocates the next revision; restoring
                            // the old revision verbatim would make a subsequent
                            // update fail the store's monotonicity check.
                            networkCapturePreferences = try await captureStore.replaceRules(
                                previousPreferences.snapshot.rules,
                                enabled: previousPreferences.enabled,
                                dnsEnabled: previousPreferences.dnsEnabled,
                                failOpen: previousPreferences.failOpen
                            )
                        } else {
                            networkCapturePreferences = previousPreferences
                        }
                    } catch {
                        appendSupervisorLog(
                            AppLocalization.format(
                                "Startup migration could not restore App Routing settings: %@",
                                error.localizedDescription
                            )
                        )
                    }
                }
            }
            let message = error.localizedDescription
            startupPreparationErrorMessage = message
            errorMessage = message
            appendSupervisorLog("Startup preparation failed: \(message)")
        }
    }

    private func connectActiveProfileAtLaunchIfAvailable() async {
        guard autoConnectOnLaunch else {
            appendSupervisorLog(
                "Startup skipped automatic connect because restoring the last session is disabled."
            )
            return
        }
        guard connectionDesiredOnLaunch else {
            appendSupervisorLog(
                "Startup skipped automatic connect because the last session was left disconnected."
            )
            return
        }
        guard !systemProxyRecoveryRequired else {
            appendSupervisorLog(
                "Startup skipped automatic connect because macOS System Proxy restoration still needs attention."
            )
            return
        }
        guard let activeProfileID,
              profiles.contains(where: { $0.id == activeProfileID }),
              let activeConfigURL,
              FileManager.default.fileExists(atPath: activeConfigURL.path) else {
            appendSupervisorLog(
                "Startup skipped automatic connect because no usable active profile is available."
            )
            return
        }
        guard !shutdownInProgress,
              !Task.isCancelled,
              !isConnected,
              !isBusy else {
            return
        }

        let connected = await performConnect()
        guard !shutdownInProgress, !Task.isCancelled else { return }
        if connected, autoEnableSystemProxy, !networkCapturePreferences.enabled {
            await enableSystemProxyAfterConnect()
        }
    }

    var isConnected: Bool {
        if case .running = coreState { return true }
        return false
    }

    var isBusy: Bool {
        switch coreState {
        case .validating, .starting, .stopping:
            true
        default:
            false
        }
    }

    var statusTitle: String {
        switch coreState {
        case .stopped: AppLocalization.string("Disconnected")
        case .validating: AppLocalization.string("Checking configuration")
        case .starting: AppLocalization.string("Connecting")
        case .running: AppLocalization.string("Connected")
        case .stopping: AppLocalization.string("Disconnecting")
        case .failed: AppLocalization.string("Needs attention")
        }
    }

    var runningSession: CoreSession? {
        if case let .running(session) = coreState { return session }
        return nil
    }

    var activeProfile: ProfileMetadata? {
        guard let activeProfileID else { return nil }
        return profiles.first { $0.id == activeProfileID }
    }

    var controllerIsReady: Bool {
        controllerState == .ready
    }

    var liveDataIsDegraded: Bool {
        !degradedStreams.isEmpty
    }

    var liveMetricsAreDegraded: Bool {
        degradedStreams.contains(.traffic) || degradedStreams.contains(.connections)
    }

    var presentationTelemetryPolicy: PresentationTelemetryPolicy {
        PresentationTelemetryPolicy.resolve(
            mainWindowVisible: mainWindowPresentationTelemetryIsVisible,
            menuBarContentVisible: !lightweightMode && menuBarContentIsVisible,
            destination: selection,
            appRoutingActivityVisible: appRoutingActivityViewIsVisible,
            menuBarStatusVisible: !lightweightMode && menuBarDisplayStyle == .proxyStatus
        )
    }

    func setMainWindowVisible(_ isVisible: Bool) {
        guard mainWindowIsVisible != isVisible else { return }
        mainWindowIsVisible = isVisible
    }

    func setMainWindowPresentationTelemetryVisible(_ isVisible: Bool) {
        guard mainWindowPresentationTelemetryIsVisible != isVisible else { return }
        mainWindowPresentationTelemetryIsVisible = isVisible
        presentationDemandDidChange()
    }

    func setMenuBarContentVisible(_ isVisible: Bool) {
        guard menuBarContentIsVisible != isVisible else { return }
        menuBarContentIsVisible = isVisible
        presentationDemandDidChange()
    }

    func setAppRoutingActivityViewVisible(_ isVisible: Bool) {
        guard appRoutingActivityViewIsVisible != isVisible else { return }
        appRoutingActivityViewIsVisible = isVisible
        presentationDemandDidChange()
    }

    var systemProxyEnabled: Bool {
        switch systemProxyState {
        case .on, .enabling, .disabling:
            true
        case .failed:
            hasSystemProxySnapshot
        case .off:
            false
        }
    }

    /// Whether macOS currently reports any enabled proxy protocol, including
    /// settings left by an older MClash process or another proxy utility.
    var systemProxyEffectivelyEnabled: Bool {
        systemProxyEnabled || systemProxyObservedEnabled
    }

    var systemProxyOwnershipWarning: String? {
        guard systemProxyObservedEnabled, !systemProxyEnabled else { return nil }
        return systemProxyObservedMatchesMClash
            ? AppLocalization.string(
                "macOS System Proxy is on, but MClash does not own its recovery snapshot."
            )
            : AppLocalization.string(
                "macOS System Proxy is on outside MClash and does not match the active MClash listener."
            )
    }

    var systemProxyRecoveryRequired: Bool {
        guard hasSystemProxySnapshot else { return false }
        // A guard failure means the currently intended proxy could not be
        // verified. It is distinct from failing to restore the saved previous
        // macOS configuration.
        if systemProxyGuardFailure != nil { return false }
        if case .failed = systemProxyState { return true }
        return false
    }

    var localHTTPListenerPort: Int? {
        if unifiedConfigurationEnabled,
           let port = activeConfiguredEntrances.first(where: {
               $0.kind == .http && $0.enabled
           })?.port {
            return port
        }
        if let port = positivePort(runtimeConfig?.port ?? 0) {
            return port
        }
        if let port = runtimeConfig?.listeners?.first(where: {
            $0.type?.lowercased() == "http"
        }).flatMap({ positivePort($0.port ?? 0) }) {
            return port
        }
        return activeConfiguredEntrances.first(where: { $0.kind == .http && $0.enabled })?.port
    }

    var localSOCKSListenerPort: Int? {
        if unifiedConfigurationEnabled,
           let port = activeConfiguredEntrances.first(where: {
               $0.kind == .socks5 && $0.enabled
           })?.port {
            return port
        }
        if let port = positivePort(runtimeConfig?.socksPort ?? 0) {
            return port
        }
        if let port = runtimeConfig?.listeners?.first(where: {
            $0.type?.lowercased() == "socks"
                || $0.type?.lowercased() == "socks5"
        }).flatMap({ positivePort($0.port ?? 0) }) {
            return port
        }
        return activeConfiguredEntrances.first(where: { $0.kind == .socks5 && $0.enabled })?.port
    }

    var localMixedListenerPort: Int? {
        guard let runtimeConfig else { return nil }
        if let managedMixedPort { return managedMixedPort }
        if let configured = positivePort(runtimeConfig.mixedPort) { return configured }
        return runtimeConfig.listeners?.first(where: {
            $0.type?.lowercased() == "mixed"
        }).flatMap { positivePort($0.port ?? 0) }
    }

    var localHTTPListenerAddress: String? {
        localHTTPListenerPort.map { "127.0.0.1:\($0)" }
    }

    var localSOCKSListenerAddress: String? {
        localSOCKSListenerPort.map { "127.0.0.1:\($0)" }
    }

    var localMixedListenerAddress: String? {
        localMixedListenerPort.map { "127.0.0.1:\($0)" }
    }

    var localListenerEndpoints: [LocalListenerEndpoint] {
        guard let port = localMixedListenerPort else { return [] }
        return [
            LocalListenerEndpoint(
                kind: .mixed,
                host: "127.0.0.1",
                port: port,
                source: managedMixedPort == nil ? mixedListenerConfiguredSource : .managedFallback
            )
        ]
    }

    /// All user-configured entrances in the active unified runtime. HTTP and
    /// SOCKS5 records retain their names; App Routing is represented as a
    /// capability switch with no TCP port. The internal Mixed recovery socket
    /// is deliberately excluded: it is an implementation fallback, not a
    /// fourth user policy or entrance.
    var activeConfiguredEntrances: [ActiveEntranceEndpoint] {
        guard unifiedConfigurationEnabled,
              let workspace = configurationDocument.currentWorkspace else {
            return []
        }
        let entries = workspace.entranceIDs.compactMap { id in
            configurationDocument.entrances.first(where: { $0.id == id })
        }
        return entries.map { entrance in
            ActiveEntranceEndpoint(
                id: entrance.id,
                name: entrance.name,
                kind: ActiveEntranceKind(rawValue: entrance.kind.rawValue) ?? .http,
                host: entrance.kind == .appRouting || entrance.kind == .tun
                    ? nil : entrance.bindAddress,
                port: entrance.kind == .appRouting || entrance.kind == .tun
                    ? nil : entrance.port,
                enabled: entrance.enabled
            )
        }
    }

    /// Whether startup had to create the internal Mixed recovery endpoint
    /// because the configured public listeners were unavailable.
    var managedMixedFallbackIsActive: Bool {
        managedMixedPort != nil
    }

    /// Effective HTTP endpoint used when configuring macOS. Prefer the named
    /// user entrance. A managed Mixed socket takes precedence only after a
    /// failed listener startup; an ordinary legacy Mixed port is the last
    /// compatibility fallback.
    var localHTTPProxyPort: Int? {
        if let managedMixedPort { return managedMixedPort }
        return localHTTPListenerPort ?? localMixedListenerPort
    }

    /// Effective SOCKS endpoint used when configuring macOS. See
    /// `localHTTPProxyPort` for the fallback semantics.
    var localSOCKSProxyPort: Int? {
        if let managedMixedPort { return managedMixedPort }
        return localSOCKSListenerPort ?? localMixedListenerPort
    }

    var localHTTPProxyAddress: String? {
        localHTTPProxyPort.map { "127.0.0.1:\($0)" }
    }

    var localSOCKSProxyAddress: String? {
        localSOCKSProxyPort.map { "127.0.0.1:\($0)" }
    }

    var networkStateTransitionInProgress: Bool {
        if preparationInProgress { return true }
        if case .enabling = systemProxyState { return true }
        if case .disabling = systemProxyState { return true }
        if case .enabling = networkCaptureState { return true }
        if case .awaitingUserApproval = networkCaptureState { return true }
        if case .disabling = networkCaptureState { return true }
        return operations.contains { $0.serializesNetworkState || $0.isCoreBound }
    }

    var appRoutingCapabilityEnabled: Bool {
        if unifiedConfigurationEnabled,
           let workspace = configurationDocument.currentWorkspace,
           let entrance = workspace.entranceIDs.compactMap({ id in configurationDocument.entrances.first(where: { $0.id == id }) }).first(where: { $0.kind == .appRouting }) {
            return entrance.enabled
        }
        return networkCapturePreferences.enabled
    }

    var configurationStatusMessage: String? {
        configurationDiagnostics.first(where: { $0.severity == .error })?.message ?? errorMessage
    }

    private var unifiedConfigurationMigrationCompleted: Bool {
        preferenceDefaults.integer(
            forKey: Self.unifiedConfigurationMigrationVersionKey
        ) >= Self.unifiedConfigurationMigrationVersion
    }

    private func shouldAutomaticallyMigrateToUnifiedConfiguration() -> Bool {
        guard !unifiedConfigurationEnabled,
              !unifiedConfigurationMigrationCompleted,
              !profiles.isEmpty,
              !configurationDocument.nodes.isEmpty,
              configurationDocument.currentWorkspace != nil else {
            return false
        }
        return true
    }

    private func markUnifiedConfigurationMigrationCompleted() {
        preferenceDefaults.set(
            Self.unifiedConfigurationMigrationVersion,
            forKey: Self.unifiedConfigurationMigrationVersionKey
        )
    }

    private func prepareDocumentForUnifiedMigration() async throws {
        guard let workspace = configurationDocument.currentWorkspace else { return }
        var candidate = configurationDocument
        var changed = false
        var migrationDiagnostics: [ConfigurationDiagnostic] = []
        let workspaceIndex = candidate.workspaces.firstIndex(where: { $0.id == workspace.id })
        let workspaceEntranceIDs = Set(workspace.entranceIDs)
        for index in candidate.entrances.indices
        where workspaceEntranceIDs.contains(candidate.entrances[index].id)
            && candidate.entrances[index].kind == .appRouting {
            if candidate.entrances[index].enabled != networkCapturePreferences.enabled {
                candidate.entrances[index].enabled = networkCapturePreferences.enabled
                changed = true
            }
        }
        let hasMeaningfulUnifiedRules = candidate.rules.contains {
            $0.enabled || !$0.matchers.isEmpty
        }
        if !hasMeaningfulUnifiedRules,
           !networkCapturePreferences.snapshot.rules.isEmpty,
           let workspaceIndex {
            let sourceNames = Dictionary(
                uniqueKeysWithValues: profiles.map {
                    (SourceID(rawValue: $0.id.rawValue), $0.name)
                }
            )
            let migration = ConfigurationLegacyMigration.migrate(
                captureRules: networkCapturePreferences.snapshot.rules,
                document: candidate,
                workspace: workspace,
                sourceNames: sourceNames
            )
            if !migration.rules.isEmpty {
                // The current workspace is being replaced by the migrated
                // App Routing rules. Preserve rules owned by another
                // workspace, including disabled legacy rules, so those
                // workspaces do not retain dangling rule IDs after startup.
                let otherWorkspaceRuleIDs = Set(
                    candidate.workspaces
                        .filter { $0.id != workspace.id }
                        .flatMap(\.ruleIDs)
                )
                let preservedRules = candidate.rules.filter { rule in
                    otherWorkspaceRuleIDs.contains(rule.id)
                }
                let migratedRuleIDs = Set(migration.rules.map(\.id))
                candidate.rules = preservedRules.filter {
                    !migratedRuleIDs.contains($0.id)
                } + migration.rules
                candidate.proxyGroups = migration.proxyGroups
                candidate.workspaces[workspaceIndex].proxyGroupIDs =
                    migration.workspaceProxyGroupIDs
                candidate.workspaces[workspaceIndex].ruleIDs =
                    migration.rules.map(\.id)
                migrationDiagnostics = migration.diagnostics
                changed = true
                appendSupervisorLog(
                    AppLocalization.format(
                        "Migrated %@ legacy App Routing rules into the unified Rules workspace; %@ rules require review.",
                        AppLocalization.number(migration.migratedCount),
                        AppLocalization.number(migration.skippedCount)
                    )
                )
            }
        }
        if networkCapturePreferences.dnsEnabled,
           let dnsIndex = candidate.dnsPolicies.firstIndex(
               where: { $0.id == workspace.dnsPolicyID }
           ),
           !candidate.dnsPolicies[dnsIndex].takeoverEnabled {
            candidate.dnsPolicies[dnsIndex].takeoverEnabled = true
            changed = true
        }
        guard changed else { return }
        if let workspaceIndex {
            candidate.workspaces[workspaceIndex].revision += 1
        }
        try await persistConfigurationDocument(candidate)
        if !migrationDiagnostics.isEmpty {
            configurationDiagnostics = (
                configurationDiagnostics + migrationDiagnostics
            )
            .reduce(into: [String: ConfigurationDiagnostic]()) {
                $0[$1.id] = $1
            }
            .map(\.value)
            .sorted { $0.id < $1.id }
        }
    }

    func isPerforming(_ operation: Operation) -> Bool {
        operations.contains(operation)
    }

    func canPerform(_ operation: Operation) -> Bool {
        if preparationInProgress { return false }
        if case .enabling = systemProxyState, operation != .changeSystemProxy { return false }
        if case .disabling = systemProxyState, operation != .changeSystemProxy { return false }
        if operations.contains(operation) { return false }
        if operation.serializesNetworkState {
            if operation == .connection || operation == .changeSystemProxy {
                if operations.contains(where: \.serializesNetworkState) { return false }
            } else if operations.contains(where: { $0.serializesNetworkState || $0.isCoreBound }) {
                return false
            }
        }
        if operation.isCoreBound,
           operations.contains(where: \.serializesNetworkState) {
            return false
        }
        return true
    }

    /// Rebuilds only the source/node side of the authoritative configuration.
    /// Existing MClash groups, rules, DNS policies and workspace choices are
    /// intentionally preserved across every refresh.
    // Internal so the configuration refresh path can be exercised without
    // starting a core in integration/unit tests. Production callers still
    // invoke it through the profile lifecycle below.
    func synchronizeConfigurationSources() async {
        guard let configurationStore, let profileStore else { return }
        var document = configurationDocument
        if document == .empty { document = .mclashDefault() }
        // Older unified workspaces were materialized with one explicit ID per
        // enabled catalog node. That representation looks like a narrowed
        // scope after a subscription refresh (especially when an old node is
        // already source-removed), and consequently prevents newly imported
        // nodes from entering the workspace. Capture this before mutating the
        // catalog: an exact all-enabled catalog is the legacy spelling of the
        // dynamic, empty scope. Keep genuinely narrowed workspaces listed.
        let legacyAllNodeScopeWorkspaceIDs = Self.legacyAllNodeScopeWorkspaceIDs(
            in: document
        )
        do {
            let storedProfiles = try await profileStore.profiles()
            let now = Date()
            var sourceRefreshSucceeded: [SourceID: Bool] = [:]
            var sourceNodeIDsSeen: [SourceID: Set<NodeID>] = [:]
            var synchronizationDiagnosticsBySource: [SourceID: [ConfigurationDiagnostic]] = [:]
            for profile in storedProfiles {
                let sourceID = SourceID(rawValue: profile.id.rawValue)
                let sourceKind: ConfigurationSourceKind
                let location: String
                switch profile.origin {
                case .local:
                    sourceKind = .localFile
                    location = "local"
                case let .imported(originalFileName):
                    sourceKind = .localFile
                    location = originalFileName
                case let .remote(remote):
                    sourceKind = .subscription
                    location = remote.url.absoluteString
                }
                let data: Data
                do {
                    data = try await profileStore.configurationData(for: profile.id)
                } catch {
                    let diagnostic = ConfigurationDiagnostic(
                        severity: .error,
                        code: "source_read_failed",
                        subject: sourceID.rawValue.uuidString.lowercased(),
                        message: AppLocalization.format(
                            "Configuration source could not be read: %@",
                            error.localizedDescription
                        )
                    )
                    var failedSource = document.sources.first(where: { $0.id == sourceID }) ?? Source(
                        id: sourceID,
                        kind: sourceKind,
                        displayName: profile.name,
                        location: location
                    )
                    failedSource.kind = sourceKind
                    failedSource.displayName = profile.name
                    failedSource.location = location
                    failedSource.lastFetchedAt = now
                    failedSource.parseDiagnostics = [diagnostic]
                    if let index = document.sources.firstIndex(where: { $0.id == sourceID }) {
                        document.sources[index] = failedSource
                    } else {
                        document.sources.append(failedSource)
                    }
                    sourceRefreshSucceeded[sourceID] = false
                    synchronizationDiagnosticsBySource[sourceID, default: []].append(diagnostic)
                    continue
                }
                let report = NodeOnlyImporter().importNodes(sourceID: sourceID, yaml: data, now: now)
                var source = document.sources.first(where: { $0.id == sourceID }) ?? Source(
                    id: sourceID,
                    kind: sourceKind,
                    displayName: profile.name,
                    location: location
                )
                source.kind = sourceKind
                source.displayName = profile.name
                source.location = location
                source.revision += 1
                source.lastFetchedAt = now
                let existingSourceNodeIDs = Set(document.nodes.compactMap { node in
                    node.sourceLinks.contains(sourceID) ? node.id : nil
                })
                let parseWasPartial = report.diagnostics.contains { diagnostic in
                    switch diagnostic.code {
                    case "node_unsupported_protocol", "node_missing_endpoint", "node_invalid_endpoint":
                        true
                    default:
                        false
                    }
                }
                let degradedRefresh = !report.hasErrors && parseWasPartial
                let degradedEmptyRefresh = !report.hasErrors
                    && report.nodes.isEmpty
                    && !existingSourceNodeIDs.isEmpty
                let refreshAuthoritative = !report.hasErrors
                    && !degradedRefresh
                    && !degradedEmptyRefresh
                source.lastSuccessfulParseAt = refreshAuthoritative
                    ? now
                    : source.lastSuccessfulParseAt
                source.rawSnapshotReference = profile.id.description
                source.parseDiagnostics = report.diagnostics
                sourceRefreshSucceeded[sourceID] = refreshAuthoritative
                if degradedRefresh || degradedEmptyRefresh {
                    let diagnostic = ConfigurationDiagnostic(
                        severity: .warning,
                        code: "source_refresh_degraded",
                        subject: sourceID.rawValue.uuidString.lowercased(),
                        message: AppLocalization.string(
                            "The source refresh was incomplete; existing nodes were kept until the source can be parsed successfully."
                        )
                    )
                    source.parseDiagnostics.append(diagnostic)
                    synchronizationDiagnosticsBySource[sourceID, default: []].append(diagnostic)
                }
                if let index = document.sources.firstIndex(where: { $0.id == sourceID }) {
                    document.sources[index] = source
                } else {
                    document.sources.append(source)
                }

                let sourceSnapshotNodes = document.nodes
                let reportCountByFingerprint = Dictionary(
                    grouping: report.nodes,
                    by: { $0.fingerprint }
                ).mapValues(\.count)
                var claimedIndices = Set<Int>()
                for node in report.nodes {
                    let matchingIndices = sourceSnapshotNodes.indices.filter {
                        sourceSnapshotNodes[$0].fingerprint == node.fingerprint
                            || Node.makeFingerprint(
                                protocol: sourceSnapshotNodes[$0].proto,
                                host: sourceSnapshotNodes[$0].host,
                                port: sourceSnapshotNodes[$0].port,
                                parameters: sourceSnapshotNodes[$0].parameters
                            ) == node.fingerprint
                    }.filter { !claimedIndices.contains($0) }
                    let prioritizedMatchingIndices = matchingIndices.sorted { lhs, rhs in
                        let leftIsSourceLinked = sourceSnapshotNodes[lhs].sourceLinks.contains(sourceID)
                        let rightIsSourceLinked = sourceSnapshotNodes[rhs].sourceLinks.contains(sourceID)
                        if leftIsSourceLinked != rightIsSourceLinked { return leftIsSourceLinked }
                        return lhs < rhs
                    }
                    let exactIndex = prioritizedMatchingIndices.first {
                        sourceSnapshotNodes[$0].connectionFingerprint == node.connectionFingerprint
                    }
                    let knownSourceIndices = prioritizedMatchingIndices.filter {
                        sourceSnapshotNodes[$0].sourceLinks.contains(sourceID)
                    }
                    // v1.4.5's first node-only importer could persist an
                    // empty quoted placeholder for a nested transport map
                    // (for example ws-opts or reality-opts). The repaired
                    // importer now has a different endpoint fingerprint, so
                    // use the source-scoped endpoint and presentation name as
                    // a one-time reconciliation bridge. This preserves fixed
                    // NodeIDs and group pins without merging two credentials
                    // that share an endpoint.
                    let legacyRepairCandidates = sourceSnapshotNodes.indices.filter { index in
                        let existing = sourceSnapshotNodes[index]
                        guard existing.sourceLinks.contains(sourceID),
                              !claimedIndices.contains(index),
                              existing.proto == node.proto,
                              existing.host == node.host,
                              existing.port == node.port,
                              existing.parameters.contains(where: { key, value in
                                  Self.legacyNestedParameterKeys.contains(
                                      NodeIdentity.normalizeParameterKey(key)
                                  ) && Self.isLegacyNestedValuePlaceholder(value)
                              })
                        else {
                            return false
                        }
                        return true
                    }
                    let namedLegacyRepairCandidates = legacyRepairCandidates.filter { index in
                        let existing = sourceSnapshotNodes[index]
                        let existingName = (existing.userAlias ?? existing.displayName)
                            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
                        let incomingName = node.displayName
                            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
                        return existingName == incomingName
                    }
                    let mergeIndex: Int?
                    if let exactIndex {
                        mergeIndex = exactIndex
                    } else if reportCountByFingerprint[node.fingerprint] == 1,
                              knownSourceIndices.count == 1,
                              Set(sourceSnapshotNodes[knownSourceIndices[0]].sourceLinks) == Set([sourceID]) {
                        // A single advertised endpoint with changed
                        // credentials is the unambiguous refresh case only
                        // when this source exclusively owns the old record.
                        // A shared record may still be used by another source
                        // with the previous credential; split it instead of
                        // silently overwriting that source's connection.
                        mergeIndex = knownSourceIndices[0]
                    } else if namedLegacyRepairCandidates.count == 1 {
                        mergeIndex = namedLegacyRepairCandidates[0]
                    } else if legacyRepairCandidates.count == 1 {
                        mergeIndex = legacyRepairCandidates[0]
                    } else {
                        // Multiple credentials at one endpoint are ambiguous
                        // without a provider-issued stable ID. Keep each new
                        // connection as a separate record and mark unmatched
                        // old records source-removed below.
                        mergeIndex = nil
                    }
                    if let index = mergeIndex {
                        claimedIndices.insert(index)
                        let merged = document.nodes[index]
                        var sourceLinks = merged.sourceLinks
                        if !sourceLinks.contains(sourceID) { sourceLinks.append(sourceID) }
                        // Rebuild through Node.init so a node loaded from an
                        // older manifest receives the current normalized
                        // endpoint fingerprint instead of retaining stale
                        // credential-sensitive identity material.
                        document.nodes[index] = try Node(
                            id: merged.id,
                            displayName: merged.userAlias ?? node.displayName,
                            protocol: node.proto,
                            host: node.host,
                            port: node.port,
                            parameters: node.parameters,
                            sourceLinks: sourceLinks,
                            tags: node.tags.isEmpty ? merged.tags : node.tags,
                            region: node.region ?? merged.region,
                            enabled: merged.enabled,
                            health: NodeHealthSnapshot(
                                availability: .available,
                                latencyMilliseconds: merged.health.latencyMilliseconds,
                                checkedAt: merged.health.checkedAt
                            ),
                            userAlias: merged.userAlias,
                            lastSeenAt: now
                        )
                        sourceNodeIDsSeen[sourceID, default: []].insert(merged.id)
                    } else {
                        if !matchingIndices.isEmpty {
                            synchronizationDiagnosticsBySource[sourceID, default: []].append(.init(
                                severity: .warning,
                                code: "node_identity_conflict",
                                subject: node.fingerprint,
                                message: AppLocalization.string(
                                    "Two sources provide the same node endpoint with different credentials; both connection identities were retained."
                                )
                            ))
                        }
                        let nodeToAppend: Node
                        if document.nodes.contains(where: { $0.id == node.id }) {
                            // A malformed provider can still reuse the
                            // disambiguated ID. Derive a source-scoped fallback
                            // rather than creating a duplicate persisted ID.
                            let fallbackID = NodeID.stable(for: node.fingerprint + "|" + node.connectionFingerprint + "|" + sourceID.rawValue.uuidString)
                            nodeToAppend = try Node(
                                id: fallbackID,
                                displayName: node.displayName,
                                protocol: node.proto,
                                host: node.host,
                                port: node.port,
                                parameters: node.parameters,
                                sourceLinks: node.sourceLinks,
                                tags: node.tags,
                                region: node.region,
                                enabled: node.enabled,
                                health: node.health,
                                userAlias: node.userAlias,
                                lastSeenAt: node.lastSeenAt
                            )
                        } else {
                            nodeToAppend = node
                        }
                        document.nodes.append(nodeToAppend)
                        sourceNodeIDsSeen[sourceID, default: []].insert(nodeToAppend.id)
                    }
                }

                // A successful refresh is authoritative for this source. Any
                // previously linked node that was not matched is retained for
                // audit, but marked source-removed rather than silently
                // re-used for a different endpoint or credential.
                if refreshAuthoritative {
                    let liveIDs = sourceNodeIDsSeen[sourceID, default: []]
                    for index in document.nodes.indices
                    where existingSourceNodeIDs.contains(document.nodes[index].id)
                        && !liveIDs.contains(document.nodes[index].id) {
                        document.nodes[index].sourceLinks.removeAll { $0 == sourceID }
                        if document.nodes[index].sourceLinks.isEmpty {
                            document.nodes[index].health.availability = .sourceRemoved
                        }
                    }
                }
            }

            // Source diagnostics are persisted for the next launch, while
            // synchronization diagnostics are also kept in the in-memory
            // aggregate used by the attention UI.  Merge by stable diagnostic
            // ID so a read/degraded/conflict warning is never shown twice.
            for (sourceID, diagnostics) in synchronizationDiagnosticsBySource {
                guard let sourceIndex = document.sources.firstIndex(where: { $0.id == sourceID }) else { continue }
                var knownIDs = Set(document.sources[sourceIndex].parseDiagnostics.map(\.id))
                for diagnostic in diagnostics where knownIDs.insert(diagnostic.id).inserted {
                    document.sources[sourceIndex].parseDiagnostics.append(diagnostic)
                }
            }
            let synchronizationDiagnostics = synchronizationDiagnosticsBySource
                .values
                .flatMap { $0 }
                .reduce(into: [String: ConfigurationDiagnostic]()) { result, diagnostic in
                    result[diagnostic.id] = diagnostic
                }
                .values

            let activeSourceIDs = Set(storedProfiles.map { SourceID(rawValue: $0.id.rawValue) })
            for index in document.sources.indices where !activeSourceIDs.contains(document.sources[index].id) {
                if !document.sources[index].parseDiagnostics.contains(where: { $0.code == "source_removed" }) {
                    document.sources[index].parseDiagnostics.append(.init(
                        severity: .warning,
                        code: "source_removed",
                        subject: document.sources[index].id.rawValue.uuidString.lowercased(),
                        message: AppLocalization.string(
                            "The original profile was removed; its raw snapshot is retained for audit and its nodes are marked source-removed."
                        )
                    ))
                }
            }

            for index in document.nodes.indices {
                let hasLiveSource = document.nodes[index].sourceLinks.contains { sourceID in
                    sourceNodeIDsSeen[sourceID]?.contains(document.nodes[index].id) == true
                }
                let hasFailedSourceRefresh = document.nodes[index].sourceLinks.contains { sourceID in
                    sourceRefreshSucceeded[sourceID] == false
                }
                if hasLiveSource {
                    document.nodes[index].health.availability = .available
                } else if !hasFailedSourceRefresh && !document.nodes[index].sourceLinks.isEmpty {
                    document.nodes[index].health.availability = .sourceRemoved
                }
            }

            // Convert the legacy materialized-all scope only after the source
            // refresh has completed. This makes the migration safe for a
            // partial refresh and lets the next compile include newly added
            // nodes immediately, while preserving explicit user subsets.
            for index in document.workspaces.indices
            where legacyAllNodeScopeWorkspaceIDs.contains(document.workspaces[index].id)
                && !document.workspaces[index].nodeIDs.isEmpty {
                document.workspaces[index].nodeIDs = []
                document.workspaces[index].revision += 1
            }

            // Keep the built-in group dynamic as the catalog grows. Older
            // manifests may contain a static list produced by the first
            // implementation; migrate that exact “all nodes” list to a
            // selector, but never rewrite a user-customized group.
            if let index = document.proxyGroups.firstIndex(where: { $0.name == "MClash Select" }) {
                let group = document.proxyGroups[index]
                let existing = Set(group.members.compactMap { member -> NodeID? in
                    if case let .node(id) = member { return id }
                    return nil
                })
                let allEnabled = Set(document.nodes.filter(\.enabled).map(\.id))
                if group.memberSelectors.isEmpty, !existing.isEmpty, existing == allEnabled {
                    document.proxyGroups[index].members.removeAll { member in
                        if case .node = member { return true }
                        return false
                    }
                    document.proxyGroups[index].memberSelectors = [NodeSelector(name: "All enabled nodes")]
                } else if group.memberSelectors.isEmpty, existing.isEmpty {
                    document.proxyGroups[index].memberSelectors = [NodeSelector(name: "All enabled nodes")]
                }
            }
            // Older unified manifests expanded every region selector with the
            // other regions as a fallback, making US/JP/HK groups identical.
            // Once a CUNOE source is present, repair only that known legacy
            // shape; genuinely user-authored groups remain untouched.
            if Self.hasLegacyFlattenedRegionalPreset(in: document) {
                if let repaired = try? ConfigurationProxyGroupPreset.apply(
                    to: document,
                    workspaceID: document.currentWorkspace?.id
                ) {
                    document = repaired.document
                    appendSupervisorLog(
                        "Repaired legacy regional groups to use CUNOE-Proxy source selectors."
                    )
                }
            }
            try await configurationStore.save(document)
            configurationDocument = document
            let sourceDiagnostics = document.sources.flatMap(\.parseDiagnostics)
            var synchronizationResults = document.diagnostics()
                + sourceDiagnostics
                + Array(synchronizationDiagnostics)
            if unifiedConfigurationEnabled {
                do {
                    let refreshedCompiledConfiguration = try ConfigurationCompiler().compile(
                        document: document
                    )
                    compiledConfiguration = refreshedCompiledConfiguration
                    synchronizationResults.append(contentsOf: refreshedCompiledConfiguration.diagnostics)
                    do {
                        try await synchronizeCompiledCaptureState(
                            refreshedCompiledConfiguration
                        )
                    } catch {
                        synchronizationResults.append(.init(
                            severity: .error,
                            code: "configuration_compile_failed",
                            subject: "runtime",
                            message: AppLocalization.format(
                                "MClash could not synchronize the refreshed runtime configuration: %@",
                                error.localizedDescription
                            )
                        ))
                    }
                } catch {
                    // Keep the last known-good compiled snapshot for recovery,
                    // but make the failed refresh actionable instead of
                    // silently presenting a stale runtime as current.
                    synchronizationResults.append(.init(
                        severity: .error,
                        code: "configuration_compile_failed",
                        subject: "configuration",
                        message: AppLocalization.format(
                            "MClash could not compile the refreshed configuration: %@",
                            error.localizedDescription
                        )
                    ))
                }
            }
            configurationDiagnostics = synchronizationResults
                .reduce(into: [String: ConfigurationDiagnostic]()) { result, diagnostic in
                    result[diagnostic.id] = diagnostic
                }
                .map(\.value)
                .sorted { $0.id < $1.id }
        } catch {
            appendSupervisorLog(
                AppLocalization.format(
                    "MClash configuration synchronization failed: %@",
                    error.localizedDescription
                )
            )
            configurationDiagnostics = [ConfigurationDiagnostic(
                severity: .error,
                code: "configuration_sync_failed",
                subject: "sources",
                message: AppLocalization.format(
                    "MClash configuration synchronization failed: %@",
                    error.localizedDescription
                )
            )]
        }
    }

    /// Returns workspaces whose explicit node list is the old materialized
    /// spelling of the complete enabled catalog. Health is deliberately not
    /// considered here: a source-removed node remains part of the catalog and
    /// must not make an otherwise all-node workspace look user-narrowed.
    static func legacyAllNodeScopeWorkspaceIDs(
        in document: ConfigurationDocument
    ) -> Set<WorkspaceID> {
        let allEnabledCatalogIDs = Set(document.nodes.filter(\.enabled).map(\.id))
        guard !allEnabledCatalogIDs.isEmpty else { return [] }
        return Set(document.workspaces.compactMap { workspace -> WorkspaceID? in
            guard !workspace.nodeIDs.isEmpty,
                  workspace.nodeIDs.count == allEnabledCatalogIDs.count,
                  Set(workspace.nodeIDs) == allEnabledCatalogIDs
            else { return nil }
            return workspace.id
        })
    }

    private static func isLegacyNestedValuePlaceholder(_ value: String) -> Bool {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return normalized.isEmpty
            || normalized == "''"
            || normalized == "\"\""
            || normalized == "{}"
            || normalized == "[]"
    }

    private static let legacyNestedParameterKeys: Set<String> = [
        "ws-opts", "reality-opts", "grpc-opts", "http-opts", "h2-opts",
        "quic-opts", "obfs-opts", "smux", "dialer-proxy",
    ]

    private static func hasLegacyFlattenedRegionalPreset(
        in document: ConfigurationDocument
    ) -> Bool {
        let hasCUNOE = document.sources.contains { source in
            source.displayName
                .unicodeScalars
                .filter { CharacterSet.alphanumerics.contains($0) }
                .map(String.init)
                .joined()
                .localizedCaseInsensitiveContains("cunoeproxy")
        }
        guard hasCUNOE else { return false }
        let regionalNames = [
            ConfigurationProxyGroupPreset.hongKongGroupName,
            ConfigurationProxyGroupPreset.unitedStatesGroupName,
            ConfigurationProxyGroupPreset.japanGroupName,
        ]
        let regionalGroups = document.proxyGroups.filter {
            regionalNames.contains($0.name)
        }
        guard regionalGroups.count == regionalNames.count else { return false }
        let foreignLabels = regionalNames
            .map { "\($0) ·" }
        return regionalGroups.contains { group in
            group.memberSelectors.contains { selector in
                foreignLabels.contains { label in
                    selector.name.hasPrefix(label)
                        && !selector.name.hasPrefix("\(group.name) ·")
                }
            }
        }
    }

    private func unifiedCaptureRules() throws -> [CaptureRule] {
        guard let compiledConfiguration else {
            throw ConfigurationCompilationError.invalidText(
                AppLocalization.string("No MClash workspace is configured.")
            )
        }
        return compiledConfiguration.captureRules
    }

    private func synchronizeCompiledCaptureState(
        _ compiled: CompiledConfiguration
    ) async throws {
        guard let store = networkCaptureConfigurationStore else {
            throw AppModelError.profileStoreUnavailable
        }
        guard networkCapturePreferences.snapshot.rules != compiled.captureRules
                || networkCapturePreferences.enabled != compiled.captureEnabled
                || networkCapturePreferences.dnsEnabled != compiled.captureDNSEnabled
        else { return }
        networkCapturePreferences = try await store.replaceRules(
            compiled.captureRules,
            enabled: compiled.captureEnabled,
            dnsEnabled: compiled.captureDNSEnabled,
            failOpen: networkCapturePreferences.failOpen
        )
    }

    func saveConfigurationDocument(_ document: ConfigurationDocument) async throws {
        guard begin(.changeRuntimeSettings) else { throw CancellationError() }
        defer { end(.changeRuntimeSettings) }
        try await persistConfigurationDocument(document)
    }

    @discardableResult
    func installCommonProxyGroupPreset() async throws -> ConfigurationProxyGroupPreset.Result {
        guard begin(.changeRuntimeSettings) else { throw CancellationError() }
        defer { end(.changeRuntimeSettings) }
        let result = try ConfigurationProxyGroupPreset.apply(
            to: configurationDocument
        )
        // The preset is a convenience authoring operation, not a validation
        // bypass. Prove the complete active workspace before saving it.
        for workspace in result.document.workspaces {
            _ = try ConfigurationCompiler().compile(
                document: result.document,
                workspaceID: workspace.id
            )
        }
        try await persistConfigurationDocument(result.document)
        return result
    }

    func configurationAutomationSnapshot(
        nodeOffset: Int = 0,
        nodeLimit: Int = 100,
        sourceOffset: Int = 0,
        sourceLimit: Int = 50
    ) -> ConfigurationAutomationSnapshot {
        let nodeOffset = min(max(0, nodeOffset), configurationDocument.nodes.count)
        let nodeLimit = min(max(1, nodeLimit), 200)
        let nodeEnd = min(configurationDocument.nodes.count, nodeOffset + nodeLimit)
        let sourceOffset = min(max(0, sourceOffset), configurationDocument.sources.count)
        let sourceLimit = min(max(1, sourceLimit), 100)
        let sourceEnd = min(configurationDocument.sources.count, sourceOffset + sourceLimit)
        let projectedDiagnostics = configurationAutomationDiagnosticProjection(
            configurationDiagnostics
        )
        return ConfigurationAutomationSnapshot(
            configurationRevision: configurationRevision.uuidString.lowercased(),
            document: ConfigurationAutomationDocument(configurationDocument),
            sources: ConfigurationAutomationPage(
                items: configurationDocument.sources[sourceOffset..<sourceEnd].map {
                ConfigurationAutomationSourceSummary(
                    id: $0.id.rawValue.uuidString.lowercased(),
                    kind: $0.kind,
                    displayName: String(redactedDiagnosticText($0.displayName).prefix(256)),
                    revision: $0.revision,
                    lastFetchedAt: $0.lastFetchedAt,
                    lastSuccessfulParseAt: $0.lastSuccessfulParseAt,
                    diagnosticCount: $0.parseDiagnostics.count
                )
                },
                offset: sourceOffset,
                limit: sourceLimit,
                total: configurationDocument.sources.count,
                hasMore: sourceEnd < configurationDocument.sources.count
            ),
            nodes: ConfigurationAutomationPage(
                items: configurationDocument.nodes[nodeOffset..<nodeEnd].map { node in
                    let projectedTags = configurationAutomationProjectedTags(node.tags)
                    return ConfigurationAutomationNodeSummary(
                        id: node.id.rawValue.uuidString.lowercased(),
                        displayName: String(redactedDiagnosticText(node.displayName).prefix(256)),
                        proto: node.proto,
                        port: node.port,
                        sourceLinks: node.sourceLinks
                            .prefix(ConfigurationAutomationLimits.returnedNodeSourceLinks)
                            .map {
                            $0.rawValue.uuidString.lowercased()
                        },
                        sourceLinkCount: node.sourceLinks.count,
                        enabled: node.enabled,
                        health: node.health,
                        userAlias: node.userAlias.map {
                            String(redactedDiagnosticText($0).prefix(256))
                        },
                        tags: projectedTags ?? [],
                        tagCount: node.tags.count,
                        region: node.region.map {
                            String(redactedDiagnosticText($0).prefix(128))
                        },
                        lastSeenAt: node.lastSeenAt,
                        parameterKeys: node.parameters.keys.sorted().prefix(64).map {
                            String($0.prefix(128))
                        },
                        parameterKeyCount: node.parameters.count
                    )
                },
                offset: nodeOffset,
                limit: nodeLimit,
                total: configurationDocument.nodes.count,
                hasMore: nodeEnd < configurationDocument.nodes.count
            ),
            currentWorkspaceID: configurationDocument.currentWorkspaceID?
                .rawValue.uuidString.lowercased(),
            lastRuntimeSnapshot: configurationDocument.lastRuntimeSnapshot.map(
                ConfigurationAutomationRuntimeSnapshot.init
            ),
            unifiedConfigurationEnabled: unifiedConfigurationEnabled,
            diagnostics: projectedDiagnostics.values,
            diagnosticCount: projectedDiagnostics.total
        )
    }

    func configurationAutomationSelectorData(
        groupID: ProxyGroupID,
        expectedRevision: UUID
    ) throws -> Data {
        try requireConfigurationRevision(expectedRevision)
        guard let group = configurationDocument.proxyGroups.first(where: {
            $0.id == groupID
        }) else {
            throw ConfigurationAutomationError.invalidInput("Unknown proxy group id")
        }
        return try JSONEncoder.automation.encode(
            group.memberSelectors.map(ConfigurationAutomationNodeSelector.init)
        )
    }

    func planConfigurationAutomationDocument(
        _ document: ConfigurationAutomationDocument,
        expectedRevision: UUID
    ) throws -> ConfigurationAutomationPlan {
        try requireConfigurationRevision(expectedRevision)
        let plan = try makeConfigurationAutomationPlan(
            candidate: document.applying(to: configurationDocument)
        )
        try requireConfigurationAutomationPlanBudget(plan)
        return plan
    }

    func applyConfigurationAutomationDocument(
        _ document: ConfigurationAutomationDocument,
        expectedRevision: UUID
    ) async throws -> ConfigurationAutomationPlan {
        guard begin(.changeRuntimeSettings) else {
            throw ConfigurationAutomationError.operationInProgress
        }
        defer { end(.changeRuntimeSettings) }
        try requireConfigurationRevision(expectedRevision)
        let candidate = try document.applying(to: configurationDocument)
        let plan = try makeConfigurationAutomationPlan(candidate: candidate)
        try requireConfigurationAutomationPlanBudget(plan)
        guard plan.valid else {
            throw ConfigurationAutomationError.invalidConfiguration(plan.diagnostics)
        }
        try requireConfigurationAutomationMutationBudget(
            candidate: candidate,
            plan: plan
        )
        if plan.changed {
            try await persistConfigurationDocument(candidate)
        }
        return plan
    }

    func deleteConfigurationAutomationObject(
        kind: ConfigurationAutomationObjectKind,
        id: UUID,
        expectedRevision: UUID
    ) async throws -> ConfigurationAutomationPlan {
        guard begin(.changeRuntimeSettings) else {
            throw ConfigurationAutomationError.operationInProgress
        }
        defer { end(.changeRuntimeSettings) }
        try requireConfigurationRevision(expectedRevision)
        let dependencies = configurationAutomationDependencies(kind: kind, id: id)
        guard dependencies.isEmpty else {
            throw ConfigurationAutomationError.dependencies(dependencies)
        }

        var candidate = configurationDocument
        let removed: Bool
        switch kind {
        case .proxyGroup:
            let count = candidate.proxyGroups.count
            candidate.proxyGroups.removeAll { $0.id == ProxyGroupID(rawValue: id) }
            removed = candidate.proxyGroups.count != count
        case .rule:
            let count = candidate.rules.count
            candidate.rules.removeAll { $0.id == RoutingRuleID(rawValue: id) }
            removed = candidate.rules.count != count
        case .ruleSet:
            let count = candidate.ruleSets.count
            candidate.ruleSets.removeAll { $0.id == RuleSetID(rawValue: id) }
            removed = candidate.ruleSets.count != count
        case .dnsPolicy:
            let count = candidate.dnsPolicies.count
            candidate.dnsPolicies.removeAll { $0.id == DNSPolicyID(rawValue: id) }
            removed = candidate.dnsPolicies.count != count
        case .entrance:
            let count = candidate.entrances.count
            candidate.entrances.removeAll { $0.id == EntranceID(rawValue: id) }
            removed = candidate.entrances.count != count
        case .workspace:
            let count = candidate.workspaces.count
            candidate.workspaces.removeAll { $0.id == WorkspaceID(rawValue: id) }
            removed = candidate.workspaces.count != count
        }
        guard removed else {
            throw ConfigurationAutomationError.invalidInput(
                "Unknown \(kind.rawValue) id"
            )
        }
        bumpConfigurationWorkspaceRevisions(in: &candidate)
        let plan = try makeConfigurationAutomationPlan(candidate: candidate)
        try requireConfigurationAutomationPlanBudget(plan)
        guard plan.valid else {
            throw ConfigurationAutomationError.invalidConfiguration(plan.diagnostics)
        }
        try requireConfigurationAutomationMutationBudget(
            candidate: candidate,
            plan: plan
        )
        try await persistConfigurationDocument(candidate)
        return plan
    }

    private func persistConfigurationDocument(_ document: ConfigurationDocument) async throws {
        guard let configurationStore else { throw ConfigurationStoreError.unavailable }
        let diagnostics = allConfigurationDiagnostics(for: document)
        try await configurationStore.save(document)
        configurationDocument = document
        configurationDiagnostics = diagnostics
    }

    private func recoverInterruptedConfigurationActivationIfNeeded() async throws {
        guard let configurationStore,
              let journal = try await configurationStore.loadActivationJournal() else {
            return
        }
        if let snapshot = configurationDocument.lastRuntimeSnapshot,
           snapshot.applicationSucceeded,
           snapshot.id != journal.previousSnapshotID,
           snapshot.workspaceID == journal.targetWorkspaceID,
           snapshot.mihomoConfigHash == journal.targetConfigHash {
            try await configurationStore.clearActivationJournal()
            return
        }
        guard let networkCaptureConfigurationStore else {
            throw AppModelError.profileStoreUnavailable
        }
        unifiedConfigurationEnabled = journal.previousUnifiedConfigurationEnabled
        let previous = journal.previousNetworkCapturePreferences
        networkCapturePreferences = try await networkCaptureConfigurationStore.replaceRules(
            previous.snapshot.rules,
            enabled: previous.enabled,
            dnsEnabled: previous.dnsEnabled,
            failOpen: previous.failOpen
        )
        shouldReenableSystemProxyAfterCrash = journal.previousSystemProxyWasOn
        configurationActivationRecoveryRequiresSystemProxy = journal.previousSystemProxyWasOn
        if !journal.previousSystemProxyWasOn {
            try await configurationStore.clearActivationJournal()
        }
        appendSupervisorLog(
            AppLocalization.string(
                "Recovered App Routing settings from an interrupted MClash Workspace activation."
            )
        )
    }

    private func requireConfigurationRevision(_ expected: UUID) throws {
        guard expected == configurationRevision else {
            throw ConfigurationAutomationError.revisionConflict(
                configurationRevision.uuidString.lowercased()
            )
        }
    }

    private func makeConfigurationAutomationPlan(
        candidate: ConfigurationDocument
    ) throws -> ConfigurationAutomationPlan {
        var diagnostics = configurationAutomationStructuralDiagnostics(candidate)
        var workspaceDiagnostics: [WorkspaceID: [ConfigurationDiagnostic]] = [:]
        if !diagnostics.contains(where: { $0.severity == .error }) {
            for workspace in candidate.workspaces {
                let values = candidate.diagnostics(for: workspace)
                workspaceDiagnostics[workspace.id] = values
                diagnostics.append(contentsOf: values)
            }
        }
        diagnostics = Dictionary(grouping: diagnostics, by: \.id)
            .compactMap { $0.value.first }
            .sorted { $0.id < $1.id }
            .map {
                ConfigurationDiagnostic(
                    severity: $0.severity,
                    code: $0.code,
                    subject: $0.subject,
                    message: String(redactedDiagnosticText($0.message).prefix(1_024))
                )
            }

        var compilations: [ConfigurationAutomationCompilation] = []
        if !diagnostics.contains(where: { $0.severity == .error }) {
            for workspace in candidate.workspaces.sorted(by: {
                $0.id.rawValue.uuidString < $1.id.rawValue.uuidString
            }) {
                do {
                    let compiled = try ConfigurationCompiler().compile(
                        document: candidate,
                        workspaceID: workspace.id,
                        validatedDiagnostics: workspaceDiagnostics[workspace.id]
                    )
                    compilations.append(ConfigurationAutomationCompilation(
                        workspaceID: workspace.id.rawValue.uuidString.lowercased(),
                        workspaceRevision: workspace.revision,
                        configHash: compiled.configHash,
                        byteCount: compiled.yaml.count,
                        captureRuleCount: compiled.captureRules.count,
                        captureEnabled: compiled.captureEnabled,
                        captureDNSEnabled: compiled.captureDNSEnabled
                    ))
                } catch let error as ConfigurationCompilationError {
                    switch error {
                    case let .invalid(values):
                        diagnostics.append(contentsOf: values)
                    case let .invalidText(message):
                        diagnostics.append(ConfigurationDiagnostic(
                            severity: .error,
                            code: "configuration_compile_failed",
                            subject: workspace.id.rawValue.uuidString.lowercased(),
                            message: message
                        ))
                    }
                } catch {
                    diagnostics.append(ConfigurationDiagnostic(
                        severity: .error,
                        code: "configuration_compile_failed",
                        subject: workspace.id.rawValue.uuidString.lowercased(),
                        message: error.localizedDescription
                    ))
                }
            }
        }
        diagnostics = Dictionary(grouping: diagnostics, by: \.id)
            .compactMap { $0.value.first }
            .sorted { $0.id < $1.id }
            .map {
                ConfigurationDiagnostic(
                    severity: $0.severity,
                    code: $0.code,
                    subject: $0.subject,
                    message: String(redactedDiagnosticText($0.message).prefix(1_024))
                )
            }
        let projectedDiagnostics = configurationAutomationDiagnosticProjection(diagnostics)
        return ConfigurationAutomationPlan(
            changed: candidate != configurationDocument,
            valid: !diagnostics.contains(where: { $0.severity == .error }),
            diagnostics: projectedDiagnostics.values,
            diagnosticCount: projectedDiagnostics.total,
            compilations: compilations
        )
    }

    private func configurationAutomationDiagnosticProjection(
        _ diagnostics: [ConfigurationDiagnostic]
    ) -> (values: [ConfigurationDiagnostic], total: Int) {
        var values: [ConfigurationDiagnostic] = []
        var encodedBytes = 0
        for diagnostic in diagnostics.prefix(ConfigurationAutomationLimits.returnedDiagnostics) {
            let projected = ConfigurationDiagnostic(
                severity: diagnostic.severity,
                code: diagnostic.code,
                subject: String(diagnostic.subject.prefix(256)),
                message: String(redactedDiagnosticText(diagnostic.message).prefix(1_024))
            )
            guard let data = try? JSONEncoder.automation.encode(projected) else { break }
            let separatorBytes = values.isEmpty ? 0 : 1
            let (nextBytes, overflow) = encodedBytes.addingReportingOverflow(
                data.count + separatorBytes
            )
            guard !overflow,
                  nextBytes <= ConfigurationAutomationLimits.returnedDiagnosticBytes else {
                break
            }
            values.append(projected)
            encodedBytes = nextBytes
        }
        return (values, diagnostics.count)
    }

    private func requireConfigurationAutomationPlanBudget(
        _ plan: ConfigurationAutomationPlan
    ) throws {
        let maximum = MClashAutomationProtocol.maximumFrameSize
            - ConfigurationAutomationLimits.responseHeadroomBytes
        guard try JSONEncoder.automation.encode(plan).count <= maximum else {
            throw ConfigurationAutomationError.invalidInput(
                "Configuration plan exceeds the 1 MiB response limit"
            )
        }
    }

    private func requireConfigurationAutomationMutationBudget(
        candidate: ConfigurationDocument,
        plan: ConfigurationAutomationPlan
    ) throws {
        let projectedDiagnostics = configurationAutomationDiagnosticProjection(
            allConfigurationDiagnostics(for: candidate)
        )
        let snapshot = ConfigurationAutomationSnapshot(
            configurationRevision: configurationRevision.uuidString.lowercased(),
            document: ConfigurationAutomationDocument(candidate),
            sources: ConfigurationAutomationPage<ConfigurationAutomationSourceSummary>(
                items: [],
                offset: candidate.sources.count,
                limit: 1,
                total: candidate.sources.count,
                hasMore: false
            ),
            nodes: ConfigurationAutomationPage<ConfigurationAutomationNodeSummary>(
                items: [],
                offset: candidate.nodes.count,
                limit: 1,
                total: candidate.nodes.count,
                hasMore: false
            ),
            currentWorkspaceID: candidate.currentWorkspaceID?
                .rawValue.uuidString.lowercased(),
            lastRuntimeSnapshot: candidate.lastRuntimeSnapshot.map(
                ConfigurationAutomationRuntimeSnapshot.init
            ),
            unifiedConfigurationEnabled: unifiedConfigurationEnabled,
            diagnostics: projectedDiagnostics.values,
            diagnosticCount: projectedDiagnostics.total
        )
        let maximum = MClashAutomationProtocol.maximumFrameSize
            - ConfigurationAutomationLimits.responseHeadroomBytes
        guard try JSONEncoder.automation.encode(snapshot).count <= maximum,
              try JSONEncoder.automation.encode(plan).count <= maximum else {
            throw ConfigurationAutomationError.invalidInput(
                "Configuration response exceeds the 1 MiB protocol limit"
            )
        }
    }

    private func configurationAutomationStructuralDiagnostics(
        _ document: ConfigurationDocument
    ) -> [ConfigurationDiagnostic] {
        var result = ConfigurationValidator.automationPlanDiagnostics(
            document: document
        )
        result += configurationAutomationDuplicateDiagnostics(
            document.sources.map(\.id), code: "duplicate_source"
        )
        result += configurationAutomationDuplicateDiagnostics(
            document.nodes.map(\.id), code: "duplicate_node"
        )
        result += configurationAutomationDuplicateDiagnostics(
            document.proxyGroups.map(\.id), code: "duplicate_group"
        )
        result += configurationAutomationDuplicateDiagnostics(
            document.rules.map(\.id), code: "duplicate_rule"
        )
        result += configurationAutomationDuplicateDiagnostics(
            document.ruleSets.map(\.id), code: "duplicate_ruleset"
        )
        result += configurationAutomationDuplicateDiagnostics(
            document.dnsPolicies.map(\.id), code: "duplicate_dns_policy"
        )
        result += configurationAutomationDuplicateDiagnostics(
            document.entrances.map(\.id), code: "duplicate_entrance"
        )
        result += configurationAutomationDuplicateDiagnostics(
            document.workspaces.map(\.id), code: "duplicate_workspace"
        )
        if document.workspaces.isEmpty {
            result.append(ConfigurationDiagnostic(
                severity: .error,
                code: "missing_workspace",
                subject: "workspaces",
                message: AppLocalization.string("At least one workspace is required.")
            ))
        }
        if let currentWorkspaceID = document.currentWorkspaceID,
           !document.workspaces.contains(where: { $0.id == currentWorkspaceID }) {
            result.append(ConfigurationDiagnostic(
                severity: .error,
                code: "missing_current_workspace",
                subject: currentWorkspaceID.rawValue.uuidString.lowercased(),
                message: AppLocalization.string("The current workspace does not exist.")
            ))
        }
        let workspaceIDs = Set(document.workspaces.map(\.id))
        for rule in document.rules {
            if let scope = rule.workspaceScope, !workspaceIDs.contains(scope) {
                result.append(ConfigurationDiagnostic(
                    severity: .error,
                    code: "missing_rule_workspace",
                    subject: rule.id.rawValue.uuidString.lowercased(),
                    message: AppLocalization.string("A routing rule references a workspace that does not exist.")
                ))
            }
        }
        for entrance in document.entrances {
            if let override = entrance.workspaceOverride, !workspaceIDs.contains(override) {
                result.append(ConfigurationDiagnostic(
                    severity: .error,
                    code: "missing_entrance_workspace",
                    subject: entrance.id.rawValue.uuidString.lowercased(),
                    message: AppLocalization.string("An entrance references a workspace that does not exist.")
                ))
            }
        }
        return result
    }

    private func configurationAutomationDuplicateDiagnostics<ID: ConfigurationIdentifier>(
        _ values: [ID],
        code: String
    ) -> [ConfigurationDiagnostic] {
        var counts: [ID: Int] = [:]
        values.forEach { counts[$0, default: 0] += 1 }
        return counts.compactMap { id, count in
            guard count > 1 else { return nil }
            return ConfigurationDiagnostic(
                severity: .error,
                code: code,
                subject: id.rawValue.uuidString.lowercased(),
                message: AppLocalization.string("Configuration contains duplicate identities.")
            )
        }
    }

    private func bumpConfigurationWorkspaceRevisions(
        in document: inout ConfigurationDocument
    ) {
        for index in document.workspaces.indices {
            let revision = document.workspaces[index].revision
            document.workspaces[index].revision = revision == .max
                ? .max : revision + 1
        }
    }

    private func configurationAutomationDependencies(
        kind: ConfigurationAutomationObjectKind,
        id: UUID
    ) -> [ConfigurationAutomationDependency] {
        var dependencies: [ConfigurationAutomationDependency] = []
        func append(_ kind: String, _ id: UUID) {
            dependencies.append(ConfigurationAutomationDependency(
                kind: kind,
                id: id.uuidString.lowercased()
            ))
        }
        switch kind {
        case .proxyGroup:
            let groupID = ProxyGroupID(rawValue: id)
            for workspace in configurationDocument.workspaces
            where workspace.proxyGroupIDs.contains(groupID) {
                append("workspace", workspace.id.rawValue)
            }
            for group in configurationDocument.proxyGroups where group.members.contains(where: {
                if case let .group(memberID) = $0 { return memberID == groupID }
                return false
            }) {
                append("proxyGroup", group.id.rawValue)
            }
            for rule in configurationDocument.rules where rule.action == .proxyGroup(groupID) {
                append("rule", rule.id.rawValue)
            }
            for ruleSet in configurationDocument.ruleSets
            where ruleSet.defaultAction == .proxyGroup(groupID) {
                append("ruleSet", ruleSet.id.rawValue)
            }
            for entrance in configurationDocument.entrances
            where entrance.defaultAction == .proxyGroup(groupID) {
                append("entrance", entrance.id.rawValue)
            }
        case .rule:
            let ruleID = RoutingRuleID(rawValue: id)
            for workspace in configurationDocument.workspaces
            where workspace.ruleIDs.contains(ruleID) {
                append("workspace", workspace.id.rawValue)
            }
        case .ruleSet:
            let ruleSetID = RuleSetID(rawValue: id)
            for workspace in configurationDocument.workspaces
            where workspace.ruleSetIDs.contains(ruleSetID) {
                append("workspace", workspace.id.rawValue)
            }
        case .dnsPolicy:
            let dnsPolicyID = DNSPolicyID(rawValue: id)
            for workspace in configurationDocument.workspaces
            where workspace.dnsPolicyID == dnsPolicyID {
                append("workspace", workspace.id.rawValue)
            }
        case .entrance:
            let entranceID = EntranceID(rawValue: id)
            for workspace in configurationDocument.workspaces
            where workspace.entranceIDs.contains(entranceID) {
                append("workspace", workspace.id.rawValue)
            }
        case .workspace:
            let workspaceID = WorkspaceID(rawValue: id)
            if configurationDocument.currentWorkspace?.id == workspaceID {
                append("currentWorkspace", id)
            }
            if configurationDocument.lastRuntimeSnapshot?.workspaceID == workspaceID {
                append("runtimeSnapshot", id)
            }
            for rule in configurationDocument.rules where rule.workspaceScope == workspaceID {
                append("rule", rule.id.rawValue)
            }
            for entrance in configurationDocument.entrances
            where entrance.workspaceOverride == workspaceID {
                append("entrance", entrance.id.rawValue)
            }
        }
        return dependencies.sorted {
            $0.kind == $1.kind ? $0.id < $1.id : $0.kind < $1.kind
        }
    }

    private func allConfigurationDiagnostics(
        for document: ConfigurationDocument
    ) -> [ConfigurationDiagnostic] {
        (document.diagnostics() + document.sources.flatMap(\.parseDiagnostics))
            .reduce(into: [String: ConfigurationDiagnostic]()) { result, diagnostic in
                result[diagnostic.id] = diagnostic
            }
            .map(\.value)
            .sorted { $0.id < $1.id }
    }

    @discardableResult
    func createConfigurationWorkspace(
        name: String = "New Workspace"
    ) async throws -> WorkspaceID {
        guard begin(.changeRuntimeSettings) else { throw CancellationError() }
        defer { end(.changeRuntimeSettings) }
        var document = configurationDocument
        let dnsID: DNSPolicyID
        if let first = document.dnsPolicies.first {
            dnsID = first.id
        } else {
            let dns = DNSPolicy(name: "MClash DNS", mode: .redirHost, nameservers: ["223.5.5.5", "1.1.1.1"])
            document.dnsPolicies = [dns]
            dnsID = dns.id
        }
        let groupIDs = document.proxyGroups.filter(\.enabled).map(\.id)
        let entranceIDs = document.entrances.map(\.id)
        let workspace = Workspace(
            name: name,
            // An empty node scope means the complete enabled node catalog.
            // This lets selector-backed groups pick up newly imported nodes
            // after a refresh without rewriting the workspace.
            nodeIDs: [],
            proxyGroupIDs: groupIDs,
            ruleIDs: document.rules.filter(\.enabled).map(\.id),
            ruleSetIDs: document.ruleSets.map(\.id),
            dnsPolicyID: dnsID,
            entranceIDs: entranceIDs
        )
        document.workspaces.append(workspace)
        document.currentWorkspaceID = workspace.id
        try await persistConfigurationDocument(document)
        return workspace.id
    }

    @discardableResult
    func createConfigurationProxyGroup(
        name: String = "New Group"
    ) async throws -> ProxyGroupID {
        guard begin(.changeRuntimeSettings) else { throw CancellationError() }
        defer { end(.changeRuntimeSettings) }
        var document = configurationDocument
        let group = ProxyGroup(name: name, type: .select, enabled: false)
        document.proxyGroups.append(group)
        try await persistConfigurationDocument(document)
        return group.id
    }

    @discardableResult
    func createConfigurationDNSPolicy(
        name: String = "MClash DNS"
    ) async throws -> DNSPolicyID {
        guard begin(.changeRuntimeSettings) else { throw CancellationError() }
        defer { end(.changeRuntimeSettings) }
        var document = configurationDocument
        let policy = DNSPolicy(
            name: name,
            mode: .redirHost,
            nameservers: ["223.5.5.5", "1.1.1.1"],
            takeoverEnabled: true
        )
        document.dnsPolicies.append(policy)
        if let workspace = document.currentWorkspace,
           let index = document.workspaces.firstIndex(where: { $0.id == workspace.id }) {
            document.workspaces[index].dnsPolicyID = policy.id
            document.workspaces[index].revision += 1
        }
        try await persistConfigurationDocument(document)
        return policy.id
    }

    @discardableResult
    func createConfigurationRule() async throws -> RoutingRuleID {
        guard begin(.changeRuntimeSettings) else { throw CancellationError() }
        defer { end(.changeRuntimeSettings) }
        var document = configurationDocument
        let action: RoutingAction
        if let group = document.proxyGroups.first(where: \.enabled) {
            action = .proxyGroup(group.id)
        } else {
            action = .direct
        }
        let rule = RoutingRule(
            enabled: false,
            priority: (document.rules.map(\.priority).max() ?? 0) + 10,
            action: action
        )
        document.rules.append(rule)
        for index in document.workspaces.indices {
            if !document.workspaces[index].ruleIDs.contains(rule.id) {
                document.workspaces[index].ruleIDs.append(rule.id)
                document.workspaces[index].revision += 1
            }
        }
        try await persistConfigurationDocument(document)
        return rule.id
    }

    /// Inserts or updates one strategy-owned rule. The rule is linked to every
    /// existing configuration so a user-created rule cannot appear saved but
    /// silently remain inactive in the current configuration.
    func saveConfigurationRule(_ rule: RoutingRule) async throws {
        try await saveConfigurationRule(rule, workspaceID: nil)
    }

    /// Saves a rule and links a new rule only to the requested workspace. The
    /// legacy overload above intentionally retains its all-workspace behavior;
    /// quick actions from the traffic monitor use this scoped form so a rule
    /// observed in one configuration cannot silently affect another.
    func saveConfigurationRule(
        _ rule: RoutingRule,
        workspaceID: WorkspaceID?
    ) async throws {
        var document = configurationDocument
        let existed = document.rules.contains { $0.id == rule.id }
        if let index = document.rules.firstIndex(where: { $0.id == rule.id }) {
            document.rules[index] = rule
        } else {
            document.rules.append(rule)
        }
        if let workspaceID {
            guard let index = document.workspaces.firstIndex(where: {
                $0.id == workspaceID
            }) else {
                throw ConfigurationAutomationError.invalidInput(
                    "The selected MClash configuration does not exist"
                )
            }
            if !document.workspaces[index].ruleIDs.contains(rule.id) {
                document.workspaces[index].ruleIDs.append(rule.id)
            }
            document.workspaces[index].revision += 1
        } else {
            for index in document.workspaces.indices {
                if !document.workspaces[index].ruleIDs.contains(rule.id) {
                    document.workspaces[index].ruleIDs.append(rule.id)
                    document.workspaces[index].revision += 1
                } else if existed {
                    document.workspaces[index].revision += 1
                }
            }
        }
        try await saveConfigurationDocument(document)
    }

    func toggleConfigurationEnabled(
        section: ConfigurationWorkbenchSection,
        id: UUID
    ) async throws {
        guard begin(.changeRuntimeSettings) else { throw CancellationError() }
        defer { end(.changeRuntimeSettings) }
        var document = configurationDocument
        switch section {
        case .nodes:
            guard let index = document.nodes.firstIndex(where: { $0.id.rawValue == id }) else { return }
            document.nodes[index].enabled.toggle()
        case .proxyGroups:
            guard let index = document.proxyGroups.firstIndex(where: { $0.id.rawValue == id }) else { return }
            document.proxyGroups[index].enabled.toggle()
        case .rules:
            guard let index = document.rules.firstIndex(where: { $0.id.rawValue == id }) else { return }
            document.rules[index].enabled.toggle()
        case .ruleSets:
            guard let index = document.ruleSets.firstIndex(where: { $0.id.rawValue == id }) else { return }
            document.ruleSets[index].enabled.toggle()
        case .entrances:
            guard let index = document.entrances.firstIndex(where: { $0.id.rawValue == id }) else { return }
            document.entrances[index].enabled.toggle()
        case .dns, .workspaces, .sources:
            return
        }
        for workspaceIndex in document.workspaces.indices {
            let workspace = document.workspaces[workspaceIndex]
            let affectsWorkspace: Bool
            switch section {
            case .nodes:
                affectsWorkspace = workspace.nodeIDs.isEmpty || workspace.nodeIDs.contains { $0.rawValue == id }
            case .proxyGroups:
                affectsWorkspace = workspace.proxyGroupIDs.contains { $0.rawValue == id }
            case .rules:
                affectsWorkspace = workspace.ruleIDs.contains { $0.rawValue == id }
            case .ruleSets:
                affectsWorkspace = workspace.ruleSetIDs.contains { $0.rawValue == id }
            case .entrances:
                affectsWorkspace = workspace.entranceIDs.contains { $0.rawValue == id }
            case .dns, .workspaces, .sources:
                affectsWorkspace = false
            }
            if affectsWorkspace { document.workspaces[workspaceIndex].revision += 1 }
        }
        try await persistConfigurationDocument(document)
    }

    func compileConfiguration(workspaceID: WorkspaceID? = nil) throws -> CompiledConfiguration {
        try ConfigurationCompiler().compile(
            document: configurationDocument,
            workspaceID: workspaceID
        )
    }

    /// Compiles and applies a MClash Workspace while retaining the legacy
    /// profile bookkeeping needed by the current core fleet. The generated
    /// bytes are complete MClash YAML; source profile strategy sections are
    /// never read by this path.
    @discardableResult
    func activateConfigurationWorkspace(
        _ workspaceID: WorkspaceID,
        expectedConfigurationRevision: UUID? = nil
    ) async throws -> Bool {
        guard begin(.changeRuntimeSettings) else {
            throw ConfigurationAutomationError.operationInProgress
        }
        defer { end(.changeRuntimeSettings) }
        guard networkCaptureActivationOperation == nil,
              networkCaptureDeactivationOperation == nil,
              systemProxyEnableOperation == nil,
              systemProxyRestoreOperation == nil else {
            throw ConfigurationAutomationError.operationInProgress
        }
        switch networkCaptureState {
        case .enabling, .awaitingUserApproval, .disabling:
            throw ConfigurationAutomationError.operationInProgress
        case .off, .waitingForConnection, .on, .requiresReboot, .failed:
            break
        }
        guard let configurationStore else {
            throw ConfigurationStoreError.unavailable
        }
        guard try await configurationStore.loadActivationJournal() == nil else {
            throw ConfigurationAutomationError.operationInProgress
        }
        if let expectedConfigurationRevision {
            try requireConfigurationRevision(expectedConfigurationRevision)
        }
        guard let workspace = configurationDocument.workspaces.first(where: { $0.id == workspaceID }) else {
            throw ConfigurationAutomationError.invalidInput(
                "The selected MClash workspace does not exist"
            )
        }
        let previousDocument = configurationDocument
        let previousCompiledConfiguration = compiledConfiguration
        let previousUnifiedConfigurationEnabled = unifiedConfigurationEnabled
        let previousNetworkCapturePreferences = networkCapturePreferences
        let previousActiveConfigURL = activeConfigURL
        let shouldRestoreSystemProxy = systemProxyEnabled
        let previousNetworkCaptureWasActive: Bool = {
            if case .on = networkCaptureState { return true }
            return false
        }()
        let previousSystemProxyWasOn = systemProxyState == .on
        let previousSystemProxySnapshot: SystemProxySnapshot?
        if previousSystemProxyWasOn {
            guard let profileLayout else { throw AppModelError.profileStoreUnavailable }
            previousSystemProxySnapshot = try await systemProxyManager.loadSnapshot(
                from: systemProxySnapshotURL(layout: profileLayout)
            )
        } else {
            previousSystemProxySnapshot = nil
        }
        let compiled: CompiledConfiguration
        do {
            compiled = try compileConfiguration(workspaceID: workspace.id)
        } catch let error as ConfigurationCompilationError {
            switch error {
            case let .invalid(diagnostics):
                throw ConfigurationAutomationError.invalidConfiguration(diagnostics)
            case let .invalidText(message):
                throw ConfigurationAutomationError.invalidInput(message)
            }
        }
        let shouldReconnect = isConnected || isBusy
        let previousProfileID = activeProfileID
        guard let profileStore, let runtimeOverrideCoordinator else {
            throw AppModelError.profileStoreUnavailable
        }
        guard let activationProfileID = activeProfileID else {
            throw ConfigurationAutomationError.invalidInput(
                "Select an active Profile before activating a MClash workspace"
            )
        }
        if profileRuntimePlan.primaryProfileID != activationProfileID {
            try await loadProfileRuntimePlan()
        }
        // The core fleet keeps one managed Mixed socket (the stable local
        // compatibility endpoint) in addition to user-defined listeners. A
        // configured HTTP/SOCKS listener cannot silently claim that same port;
        // repair the durable managed port before disconnecting the healthy
        // current session.
        try await repairManagedMixedPortCollision(compiled: compiled)

        try await configurationStore.saveActivationJournal(
            ConfigurationActivationJournal(
                previousNetworkCapturePreferences: previousNetworkCapturePreferences,
                previousUnifiedConfigurationEnabled: previousUnifiedConfigurationEnabled,
                previousSystemProxyWasOn: previousSystemProxyWasOn,
                previousSnapshotID: previousDocument.lastRuntimeSnapshot?.id,
                targetWorkspaceID: workspace.id,
                targetConfigHash: compiled.configHash
            )
        )
        if shouldReconnect, !(await performDisconnect()) {
            let disconnectError = errorMessage ?? AppLocalization.string(
                "The current proxy session could not be stopped safely."
            )
            let activationError = AppModelError.profileActivationFailed(disconnectError)
            do {
                try await restoreInterruptedConfigurationDisconnect(
                    previousNetworkCapturePreferences: previousNetworkCapturePreferences,
                    networkCaptureWasActive: previousNetworkCaptureWasActive,
                    systemProxyWasOn: previousSystemProxyWasOn,
                    systemProxySnapshot: previousSystemProxySnapshot
                )
            } catch {
                activeProfileID = previousProfileID
                await refreshActiveProfileListenerPorts()
                throw NetworkCaptureTransactionFailure(
                    updateReason: activationError.localizedDescription,
                    rollbackReason: error.localizedDescription
                )
            }
            activeProfileID = previousProfileID
            await refreshActiveProfileListenerPorts()
            do {
                try await configurationStore.clearActivationJournal()
            } catch {
                throw NetworkCaptureTransactionFailure(
                    updateReason: activationError.localizedDescription,
                    rollbackReason: AppLocalization.format(
                        "MClash Workspace activation journal cleanup failed: %@",
                        error.localizedDescription
                    )
                )
            }
            throw activationError
        }
        var candidateConnectionAttempted = false
        do {
            unifiedConfigurationEnabled = true
            try await synchronizeCompiledCaptureState(compiled)
            let activation = try await runtimeOverrideCoordinator.activateCompiledConfiguration(
                activationProfileID,
                baseConfiguration: compiled.yaml,
                overrides: compiledRuntimeOverrides(for: activationProfileID),
                networkExtensionListener: activeNetworkExtensionMihomoListener,
                profileMixedListener: nil,
                routeListeners: [],
                allowedOutboundProxyNames: unifiedRuntimeProxyNames(),
                in: profileStore,
                validator: try makeProfileValidator()
            )
            activeProfileID = activation.profileID
            activeConfigURL = activation.configurationURL
            compiledConfiguration = compiled
            if shouldReconnect {
                candidateConnectionAttempted = true
                guard await performConnect() else {
                    throw AppModelError.profileActivationFailed(
                        errorMessage ?? AppLocalization.string(
                            "The MClash Workspace could not be started."
                        )
                    )
                }
                if compiled.captureEnabled {
                    switch networkCaptureState {
                    case let .on(revision)
                        where revision == networkCapturePreferences.snapshot.revision:
                        break
                    case .requiresReboot:
                        break
                    case .on, .off, .waitingForConnection, .enabling,
                         .awaitingUserApproval, .disabling, .failed:
                        throw AppModelError.profileActivationFailed(
                            AppLocalization.string(
                                "The restored App Routing configuration could not be activated."
                            )
                        )
                    }
                }
            }
            if shouldRestoreSystemProxy, !compiled.captureEnabled {
                await enableSystemProxyAfterConnect()
                guard systemProxyState == .on else {
                    throw AppModelError.systemProxyRestoreFailed
                }
            }
            var succeeded = previousDocument
            succeeded.currentWorkspaceID = workspace.id
            succeeded.lastRuntimeSnapshot = RuntimeSnapshot(
                workspaceID: workspace.id,
                workspaceRevision: workspace.revision,
                compilerVersion: ConfigurationCompiler.version,
                mihomoConfigHash: compiled.configHash,
                entranceIDs: workspace.entranceIDs,
                previousSnapshotID: previousDocument.lastRuntimeSnapshot?.id,
                applicationSucceeded: true
            )
            try await persistConfigurationDocument(succeeded)
            do {
                try await configurationStore.clearActivationJournal()
            } catch {
                appendSupervisorLog(
                    AppLocalization.format(
                        "The completed MClash Workspace activation journal could not be cleared: %@",
                        error.localizedDescription
                    )
                )
            }
            if !configurationDocument.nodes.isEmpty {
                markUnifiedConfigurationMigrationCompleted()
            }
            return shouldReconnect
        } catch {
            let activationError = error
            var rollbackFailures: [String] = []
            var safeToReconnectPreviousRuntime = true
            if candidateConnectionAttempted, !(await performDisconnect()) {
                let coresStopped = await cleanupFailedConnectionAttempt()
                let appRoutingStopped = !networkCaptureIsActive
                let systemProxyStopped = !systemProxyEnabled && !hasSystemProxySnapshot
                if !coresStopped {
                    rollbackFailures.append(
                        AppLocalization.string(
                            "the failed MClash Workspace session could not be stopped"
                        )
                    )
                }
                if !appRoutingStopped {
                    rollbackFailures.append(
                        AppLocalization.string(
                            "the failed App Routing session could not be confirmed stopped"
                        )
                    )
                }
                if !systemProxyStopped {
                    rollbackFailures.append(
                        AppLocalization.string(
                            "the failed macOS system proxy could not be confirmed restored"
                        )
                    )
                }
                safeToReconnectPreviousRuntime = coresStopped
                    && appRoutingStopped
                    && systemProxyStopped
            }
            unifiedConfigurationEnabled = previousUnifiedConfigurationEnabled
            compiledConfiguration = previousCompiledConfiguration
            activeConfigURL = previousActiveConfigURL
            activeProfileID = previousProfileID
            if previousProfileID == nil {
                activeConfigURL = nil
            }
            do {
                try await profileStore.setActiveProfile(previousProfileID)
            } catch {
                rollbackFailures.append(
                    AppLocalization.format(
                        "MClash Workspace rollback failed: %@",
                        error.localizedDescription
                    )
                )
            }
            await refreshActiveProfileListenerPorts()
            if let store = networkCaptureConfigurationStore {
                do {
                    let durablePreferences = try await store.load()
                    if durablePreferences != previousNetworkCapturePreferences {
                        networkCapturePreferences = try await store.replaceRules(
                            previousNetworkCapturePreferences.snapshot.rules,
                            enabled: previousNetworkCapturePreferences.enabled,
                            dnsEnabled: previousNetworkCapturePreferences.dnsEnabled,
                            failOpen: previousNetworkCapturePreferences.failOpen
                        )
                    } else {
                        networkCapturePreferences = previousNetworkCapturePreferences
                    }
                } catch {
                    rollbackFailures.append(
                        AppLocalization.format(
                            "saved App Routing settings: %@",
                            error.localizedDescription
                        )
                    )
                }
            }
            do {
                try await configurationStore.save(previousDocument)
                configurationDocument = previousDocument
                configurationDiagnostics = allConfigurationDiagnostics(for: previousDocument)
            } catch {
                rollbackFailures.append(
                    AppLocalization.format(
                        "MClash Workspace state rollback failed: %@",
                        error.localizedDescription
                    )
                )
                do {
                    let durableDocument = try await configurationStore.load()
                    configurationDocument = durableDocument
                    configurationDiagnostics = allConfigurationDiagnostics(for: durableDocument)
                } catch {
                    rollbackFailures.append(
                        AppLocalization.format(
                            "MClash Workspace durable state reload failed: %@",
                            error.localizedDescription
                        )
                    )
                }
            }
            // Re-activate the previous compiled workspace when possible. The
            // legacy profile path is only a fallback for upgrades that have
            // never successfully applied a MClash snapshot.
            if safeToReconnectPreviousRuntime, let previousProfileID {
                do {
                    let restored: RuntimeConfigurationActivation
                    if let previousCompiledConfiguration,
                       previousUnifiedConfigurationEnabled {
                        restored = try await runtimeOverrideCoordinator.activateCompiledConfiguration(
                            previousProfileID,
                            baseConfiguration: previousCompiledConfiguration.yaml,
                            overrides: compiledRuntimeOverrides(for: previousProfileID),
                            networkExtensionListener: activeNetworkExtensionMihomoListener,
                            profileMixedListener: nil,
                            routeListeners: [],
                            // Rollback may legitimately target the previous
                            // compiled document while the current workspace
                            // has already renamed a group; let its own
                            // validated YAML remain authoritative here.
                            allowedOutboundProxyNames: nil,
                            in: profileStore,
                            validator: try makeProfileValidator()
                        )
                    } else {
                        restored = try await activateStoredProfile(
                            previousProfileID,
                            validator: try makeProfileValidator()
                        )
                    }
                    activeConfigURL = restored.configurationURL
                    self.activeProfileID = previousProfileID
                    if shouldReconnect {
                        if await performConnect() {
                            if previousNetworkCaptureWasActive,
                               !networkCaptureState.isActive(
                                   revision: networkCapturePreferences.snapshot.revision
                               ) {
                                rollbackFailures.append(
                                    AppLocalization.string(
                                        "the previous App Routing session could not be restored"
                                    )
                                )
                            }
                            if shouldRestoreSystemProxy {
                                await enableSystemProxyAfterConnect()
                                if systemProxyState != .on {
                                    rollbackFailures.append(
                                        AppLocalization.string(
                                            "the previous macOS system proxy could not be restored"
                                        )
                                    )
                                }
                            }
                        } else {
                            rollbackFailures.append(
                                AppLocalization.string(
                                    "the previous session could not be restarted"
                                )
                            )
                        }
                    }
                } catch {
                    rollbackFailures.append(
                        AppLocalization.format(
                            "MClash Workspace rollback failed: %@",
                            error.localizedDescription
                        )
                    )
                }
            }
            if rollbackFailures.isEmpty {
                do {
                    try await configurationStore.clearActivationJournal()
                } catch {
                    rollbackFailures.append(
                        AppLocalization.format(
                            "MClash Workspace activation journal cleanup failed: %@",
                            error.localizedDescription
                        )
                    )
                }
            }
            if !rollbackFailures.isEmpty {
                throw NetworkCaptureTransactionFailure(
                    updateReason: activationError.localizedDescription,
                    rollbackReason: rollbackFailures.joined(separator: "; ")
                )
            }
            throw activationError
        }
    }

    private func restoreInterruptedConfigurationDisconnect(
        previousNetworkCapturePreferences: NetworkCapturePreferences,
        networkCaptureWasActive: Bool,
        systemProxyWasOn: Bool,
        systemProxySnapshot: SystemProxySnapshot?
    ) async throws {
        networkCapturePreferences = previousNetworkCapturePreferences
        let supervisorState = await supervisor.state()
        if case .running = supervisorState, controllerIsReady {
            try await prepareProfileRoutingSessions(
                for: previousNetworkCapturePreferences.enabled
                    ? previousNetworkCapturePreferences.snapshot.rules : [],
                captureEnabled: previousNetworkCapturePreferences.enabled,
                startAuxiliary: true
            )
        } else {
            guard await cleanupFailedConnectionAttempt() else {
                throw AppModelError.profileActivationFailed(
                    AppLocalization.string(
                        "The current proxy session could not be stopped safely."
                    )
                )
            }
            guard await performConnect(), isConnected, controllerIsReady else {
                throw AppModelError.profileActivationFailed(
                    AppLocalization.string(
                        "the previous session could not be restarted"
                    )
                )
            }
        }
        let expectedRevision = previousNetworkCapturePreferences.snapshot.revision
        if networkCaptureWasActive,
           !networkCaptureState.isActive(revision: expectedRevision) {
            await performNetworkCaptureActivation()
            guard networkCaptureState.isActive(revision: expectedRevision) else {
                throw AppModelError.profileActivationFailed(
                    AppLocalization.string(
                        "The restored App Routing configuration could not be activated."
                    )
                )
            }
        }
        guard systemProxyWasOn, systemProxyState != .on else { return }
        guard let systemProxySnapshot,
              let profileLayout,
              let endpoints = currentSystemProxyEndpoints() else {
            throw AppModelError.systemProxyRestoreFailed
        }
        let snapshotURL = systemProxySnapshotURL(layout: profileLayout)
        systemProxyState = .enabling
        do {
            try await systemProxyManager.save(
                snapshot: systemProxySnapshot,
                to: snapshotURL
            )
        } catch {
            systemProxyState = .failed(error.localizedDescription)
            throw error
        }
        do {
            try await systemProxyManager.apply(
                endpoints: endpoints,
                bypassDomains: systemProxyPreferences.effectiveBypassDomains
            )
            guard try await systemProxyManager.configurationMatches(
                endpoints: endpoints,
                bypassDomains: systemProxyPreferences.effectiveBypassDomains
            ) else {
                throw AppModelError.systemProxyGuardVerificationFailed
            }
        } catch {
            let updateError = error
            do {
                try await systemProxyManager.restoreSnapshotAndRemove(from: snapshotURL)
                systemProxyState = .off
                systemProxyObservedEnabled = false
                systemProxyObservedMatchesMClash = false
                systemProxyObservedAt = Date()
            } catch {
                systemProxyState = .failed(error.localizedDescription)
                throw NetworkCaptureTransactionFailure(
                    updateReason: updateError.localizedDescription,
                    rollbackReason: error.localizedDescription
                )
            }
            throw updateError
        }
        systemProxyGuardFailure = nil
        systemProxyGuardLastVerifiedAt = Date()
        systemProxyState = .on
        systemProxyObservedEnabled = true
        systemProxyObservedMatchesMClash = true
        systemProxyObservedAt = Date()
        startSystemProxyGuard(endpoints: endpoints)
    }

    func importProfile() async {
        guard begin(.importProfile) else { return }
        defer { end(.importProfile) }

        guard let profileStore else {
            errorMessage = AppLocalization.string(
                "The profile store could not be initialized."
            )
            return
        }

        let panel = NSOpenPanel()
        panel.title = AppLocalization.string("Import a mihomo profile")
        panel.prompt = AppLocalization.string("Import")
        panel.allowedContentTypes = [.yaml]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false

        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            let profile = try await profileStore.importProfile(from: url)
            profiles = try await profileStore.profiles()
            await synchronizeConfigurationSources()
            if activeProfileID == nil {
                try await performActivateProfile(profile.id)
            }
        } catch {
            recordOperationFailure(error, context: "Profile import")
        }
    }

    /// Imports a source for the strategy-owned node catalog without changing
    /// the active legacy Profile or runtime session.
    func importConfigurationSource() async {
        guard begin(.importProfile) else { return }
        defer { end(.importProfile) }
        guard let profileStore else {
            errorMessage = AppLocalization.string(
                "The source store could not be initialized."
            )
            return
        }
        let panel = NSOpenPanel()
        panel.title = AppLocalization.string("Add a Configuration Source")
        panel.prompt = AppLocalization.string("Add Source")
        panel.allowedContentTypes = [.yaml]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            _ = try await profileStore.importProfile(from: url)
            profiles = try await profileStore.profiles()
            await synchronizeConfigurationSources()
            errorMessage = nil
        } catch {
            let message = error.localizedDescription
            errorMessage = message
            appendSupervisorLog(
                AppLocalization.format(
                    "Configuration source import failed: %@",
                    message
                )
            )
        }
    }

    func importProfile(
        data: Data,
        suggestedFileName: String,
        activate: Bool = true
    ) async throws -> ProfileMetadata {
        guard begin(.importProfile) else {
            throw AppModelError.operationInProgress
        }
        defer { end(.importProfile) }
        guard let profileStore, let profileLayout else {
            throw AppModelError.profileStoreUnavailable
        }
        guard !data.isEmpty,
              data.count <= MClashAutomationProtocol.maximumInlineProfileSize else {
            throw AppModelError.profileActivationFailed(
                AppLocalization.format(
                    "The imported profile must be between 1 byte and %@ bytes.",
                    String(MClashAutomationProtocol.maximumInlineProfileSize)
                )
            )
        }

        let safeName = URL(fileURLWithPath: suggestedFileName).lastPathComponent
        guard !safeName.isEmpty, safeName.utf8.count <= 128,
              safeName.lowercased().hasSuffix(".yaml") || safeName.lowercased().hasSuffix(".yml") else {
            throw AppModelError.profileActivationFailed(
                AppLocalization.string(
                    "The imported profile filename must end in .yaml or .yml."
                )
            )
        }
        let stagingDirectory = profileLayout.rootDirectory
            .appendingPathComponent("Automation", isDirectory: true)
            .appendingPathComponent("Staging", isDirectory: true)
        try FileManager.default.createDirectory(
            at: stagingDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let importDirectory = stagingDirectory.appendingPathComponent(
            UUID().uuidString,
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: importDirectory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: importDirectory) }
        let stagedURL = importDirectory.appendingPathComponent(safeName, isDirectory: false)
        try data.write(to: stagedURL, options: .withoutOverwriting)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: stagedURL.path
        )
        let previousProfileID = activeProfileID
        let profile = try await profileStore.importProfile(from: stagedURL)
        profiles = try await profileStore.profiles()
        await synchronizeConfigurationSources()
        if activate {
            do {
                try await performActivateProfile(profile.id)
            } catch {
                try await rollbackNewProfile(
                    profile.id,
                    previousProfileID: previousProfileID,
                    activationError: error
                )
            }
        }
        errorMessage = nil
        return profile
    }

    func addRemoteProfile(name: String, url: URL, activate: Bool = true) async throws {
        guard begin(.addRemoteProfile) else {
            throw AppModelError.operationInProgress
        }
        defer { end(.addRemoteProfile) }

        guard let profileStore else {
            throw AppModelError.profileStoreUnavailable
        }

        do {
            let validator = try makeProfileValidator()
            let previousProfileID = activeProfileID
            let profile = try await profileStore.createRemoteProfile(
                name: name,
                subscriptionURL: url,
                validator: validator
            )
            profiles = try await profileStore.profiles()
            await synchronizeConfigurationSources()
            if activate {
                do {
                    try await performActivateProfile(profile.id)
                } catch {
                    try await rollbackNewProfile(
                        profile.id,
                        previousProfileID: previousProfileID,
                        activationError: error
                    )
                }
            }
        } catch {
            appendSupervisorLog(
                "Subscription add failed: "
                    + redactedSubscriptionMessage(error.localizedDescription, url: url)
            )
            throw error
        }
    }

    func activateProfile(_ id: ProfileID, force: Bool = false) async throws {
        guard begin(.activateProfile(id)) else {
            throw AppModelError.operationInProgress
        }
        defer { end(.activateProfile(id)) }

        do {
            try await performActivateProfile(id, force: force)
        } catch {
            appendSupervisorLog("Profile activation failed: \(error.localizedDescription)")
            throw error
        }
    }

    /// Profile creation plus activation is one automation transaction. If the
    /// candidate cannot become active, remove it so callers never receive a
    /// failure while an undisclosed persistent profile remains behind.
    private func rollbackNewProfile(
        _ createdProfileID: ProfileID,
        previousProfileID: ProfileID?,
        activationError: Error
    ) async throws -> Never {
        guard let profileStore, let profileLayout else {
            throw activationError
        }
        do {
            if try await profileStore.activeProfileID() == createdProfileID {
                try await profileStore.setActiveProfile(previousProfileID)
            }
            if activeProfileID == createdProfileID {
                activeProfileID = previousProfileID
                activeConfigURL = previousProfileID.map { _ in
                    profileLayout.runtimeConfigurationURL
                }
                await refreshActiveProfileListenerPorts()
            }
            try await removeStoredProfileAndRuntimeState(
                createdProfileID,
                nextPrimaryProfileID: previousProfileID,
                profileStore: profileStore,
                profileLayout: profileLayout
            )
        } catch {
            let message = AppLocalization.format(
                "%@ Rolling back the newly created profile failed: %@",
                activationError.localizedDescription,
                error.localizedDescription
            )
            throw AppModelError.profileActivationFailed(message)
        }
        throw activationError
    }

    /// Removes every durable and live reference before deleting profile
    /// storage. This ordering prevents a failed activation from leaving an
    /// enabled Fleet entry whose configuration directory no longer exists.
    private func removeStoredProfileAndRuntimeState(
        _ profileID: ProfileID,
        nextPrimaryProfileID: ProfileID?,
        profileStore: ProfileStore,
        profileLayout: ProfileDirectoryLayout
    ) async throws {
        guard let profileRuntimePlanStore else {
            throw AppModelError.profileStoreUnavailable
        }
        guard await coreFleet.stop(profileID: profileID) else {
            throw AppModelError.profileActivationFailed(
                AppLocalization.format(
                    "%@ could not be stopped before removal.",
                    profileDisplayName(profileID)
                )
            )
        }
        auxiliaryCoreStates = await coreFleet.states()

        let previousPlan = profileRuntimePlan
        var candidate = previousPlan
        candidate.sessions.removeAll { $0.profileID == profileID }
        candidate.routeListeners.removeAll { $0.profileID == profileID }
        if candidate.primaryProfileID == profileID {
            candidate.primaryProfileID = nextPrimaryProfileID
        }
        try ProfileRuntimePlanValidator().validate(candidate)
        try await profileRuntimePlanStore.save(candidate)
        profileRuntimePlan = candidate

        do {
            let fileManager = FileManager.default
            for directory in [
                profileLayout.runtimeSessionDirectory(for: profileID),
                profileLayout.coreHomeDirectory(for: profileID),
            ] where fileManager.fileExists(atPath: directory.path) {
                try fileManager.removeItem(at: directory)
            }
            try await profileStore.removeProfile(profileID)
            profiles = try await profileStore.profiles()
        } catch {
            var restorationFailure: Error?
            do {
                try await profileRuntimePlanStore.save(previousPlan)
                profileRuntimePlan = previousPlan
            } catch {
                restorationFailure = error
            }
            if let restorationFailure {
                throw AppModelError.profileActivationFailed(
                    AppLocalization.format(
                        "%@ Restoring the previous profile runtime plan also failed: %@",
                        error.localizedDescription,
                        restorationFailure.localizedDescription
                    )
                )
            }
            throw error
        }

        auxiliaryLaunchConfigurations[profileID] = nil
        auxiliaryCoreStates[profileID] = nil
        verifiedMClashMixedPorts[profileID] = nil
    }

    func updateProfile(
        _ id: ProfileID,
        name: String,
        subscriptionURL: URL? = nil,
        automaticUpdatesEnabled: Bool = true,
        updateIntervalHours: Int? = nil
    ) async throws {
        guard begin(.updateProfile(id)) else {
            throw AppModelError.operationInProgress
        }
        defer { end(.updateProfile(id)) }

        guard let profileStore else {
            throw AppModelError.profileStoreUnavailable
        }
        guard let profile = profiles.first(where: { $0.id == id }) else {
            throw ProfileStoreError.profileNotFound(id)
        }

        switch profile.origin {
        case .remote:
            guard let subscriptionURL else {
                throw ProfileStoreError.invalidSubscriptionURL
            }
            _ = try await profileStore.updateRemoteProfileSettings(
                id,
                name: name,
                subscriptionURL: subscriptionURL,
                automaticUpdatesEnabled: automaticUpdatesEnabled,
                updateIntervalHours: updateIntervalHours
            )
        case .local, .imported:
            _ = try await profileStore.renameProfile(id, to: name)
        }
        profiles = try await profileStore.profiles()
        errorMessage = nil
    }

    func handleIncomingURL(_ url: URL) async {
        do {
            let request = try SubscriptionURLRouter.parse(url)
            pendingSubscriptionImport = request
            selection = .sources
        } catch {
            let message = error.localizedDescription
            errorMessage = message
            appendSupervisorLog("Subscription URL import failed: \(message)")
        }
    }

    func cancelPendingSubscriptionImport() {
        pendingSubscriptionImport = nil
    }

    @discardableResult
    func confirmPendingSubscriptionImport(_ request: SubscriptionImportRequest) async -> Bool {
        guard pendingSubscriptionImport == request else { return false }
        pendingSubscriptionImport = nil

        do {
            try await addRemoteProfile(name: request.name, url: request.url, activate: false)
            selection = .sources
            errorMessage = nil
            return true
        } catch {
            let message = redactedSubscriptionMessage(
                error.localizedDescription,
                url: request.url
            )
            errorMessage = message
            appendSupervisorLog("Confirmed subscription import failed: \(message)")
            return false
        }
    }

    func setLaunchAtLogin(_ enabled: Bool) throws {
        guard begin(.changeApplicationSettings) else {
            throw AppModelError.operationInProgress
        }
        defer { end(.changeApplicationSettings) }
        let loginItemManager = LoginItemManager()
        try loginItemManager.setEnabled(enabled)
        launchAtLogin = loginItemManager.isEnabled
        launchAtLoginRequiresApproval = loginItemManager.requiresApproval
    }

    func setNotificationsEnabled(_ enabled: Bool) async {
        guard begin(.changeApplicationSettings) else { return }
        defer { end(.changeApplicationSettings) }
        if enabled {
            do {
                notificationsEnabled = try await notificationCenter.requestAuthorization()
                if !notificationsEnabled {
                    errorMessage = AppLocalization.string(
                        "macOS notification permission was not granted."
                    )
                }
            } catch {
                notificationsEnabled = false
                errorMessage = error.localizedDescription
            }
        } else {
            notificationsEnabled = false
        }
        preferenceDefaults.set(
            notificationsEnabled,
            forKey: Self.notificationsEnabledKey
        )
    }

    @discardableResult
    func exportBackup() async -> Bool? {
        guard begin(.exportBackup) else { return false }
        defer { end(.exportBackup) }
        guard let profileLayout else {
            errorMessage = AppLocalization.string(
                "The application state directory is unavailable."
            )
            return false
        }

        let panel = NSSavePanel()
        panel.title = AppLocalization.string("Export MClash Backup")
        panel.prompt = AppLocalization.string("Export")
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "MClash-\(Date().ISO8601Format().prefix(10)).mclashbackup"
        guard panel.runModal() == .OK, let destinationURL = panel.url else { return nil }

        do {
            try await profileBackupService.exportBackup(
                from: profileLayout,
                to: destinationURL
            )
            errorMessage = nil
            return true
        } catch {
            recordOperationFailure(error, context: "Backup export")
            return false
        }
    }

    @discardableResult
    func restoreBackup() async -> Bool? {
        guard begin(.restoreBackup) else { return false }
        defer { end(.restoreBackup) }
        guard let profileLayout, let profileStore else {
            errorMessage = AppLocalization.string(
                "The application state directory is unavailable."
            )
            return false
        }

        let panel = NSOpenPanel()
        panel.title = AppLocalization.string("Restore MClash Backup")
        panel.prompt = AppLocalization.string("Restore")
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let backupURL = panel.url else { return nil }

        let shouldReconnect = isConnected || isBusy
        let shouldRestoreSystemProxy = systemProxyEnabled
        if shouldReconnect, !(await performDisconnect()) { return false }

        var restoreTransaction: ProfileBackupRestoreTransaction?
        do {
            let transaction = try await profileBackupService.beginRestoreBackup(
                from: backupURL,
                to: profileLayout
            )
            restoreTransaction = transaction
            try await reloadBackupManagedState(from: profileStore)
            try await reconnectAfterBackupStateChange(
                shouldReconnect: shouldReconnect,
                shouldRestoreSystemProxy: shouldRestoreSystemProxy
            )
            await profileBackupService.commitRestoreBackup(transaction)
            restoreTransaction = nil
            errorMessage = nil
            return true
        } catch {
            let updateReason = error.localizedDescription
            var rollbackFailures: [String] = []
            var rollbackSucceeded = true

            if let restoreTransaction {
                if isConnected || isBusy || networkCaptureIsActive {
                    if !(await performDisconnect()) {
                        rollbackFailures.append(
                            AppLocalization.string(
                                "the restored runtime could not be fully stopped"
                            )
                        )
                    }
                }
                do {
                    try await profileBackupService.rollbackRestoreBackup(
                        restoreTransaction
                    )
                } catch {
                    rollbackSucceeded = false
                    rollbackFailures.append(error.localizedDescription)
                }
            }

            if restoreTransaction == nil || rollbackSucceeded {
                do {
                    try await reloadBackupManagedState(from: profileStore)
                    try await reconnectAfterBackupStateChange(
                        shouldReconnect: shouldReconnect,
                        shouldRestoreSystemProxy: shouldRestoreSystemProxy
                    )
                } catch {
                    rollbackFailures.append(error.localizedDescription)
                }
            }

            if rollbackFailures.isEmpty {
                recordOperationFailure(
                    error,
                    context: restoreTransaction == nil
                        ? "Backup restore"
                        : "Backup restore (previous state restored)"
                )
            } else {
                recordOperationFailure(
                    BackupRestoreTransactionFailure(
                        updateReason: updateReason,
                        rollbackReason: rollbackFailures.joined(separator: "; ")
                    ),
                    context: "Backup restore"
                )
            }
            return false
        }
    }

    private func reloadBackupManagedState(
        from profileStore: ProfileStore
    ) async throws {
        if let runtimeOverrideCoordinator {
            runtimeOverrides = try await runtimeOverrideCoordinator.overrides()
        } else {
            runtimeOverrides = .empty
        }
        if let systemProxyPreferencesStore {
            systemProxyPreferences = try await systemProxyPreferencesStore.load()
        } else {
            systemProxyPreferences = .defaults
        }
        if let networkCaptureConfigurationStore {
            networkCapturePreferences = try await networkCaptureConfigurationStore.load()
        } else {
            networkCapturePreferences = .defaults()
        }
        if let configurationStore {
            let recovery = try await configurationStore.loadRecoveringInvalidDocument()
            if recovery.quarantinedURL != nil {
                appendSupervisorLog(
                    AppLocalization.string(
                        "The MClash configuration document was invalid and was quarantined; a clean strategy document was created."
                    )
                )
            }
            configurationDocument = recovery.document == .empty
                ? .mclashDefault()
                : recovery.document
            configurationDiagnostics = allConfigurationDiagnostics(for: configurationDocument)
            if recovery.document == .empty {
                try await configurationStore.save(configurationDocument)
            }
        }
        if unifiedConfigurationEnabled {
            let compiled = try compileConfiguration()
            compiledConfiguration = compiled
            try await synchronizeCompiledCaptureState(compiled)
        } else {
            compiledConfiguration = nil
        }
        profiles = try await profileStore.profiles()
        activeProfileID = try await profileStore.activeProfileID()
        await refreshActiveProfileListenerPorts()
        try await loadProfileRuntimePlan()
        try await prepareProfileRoutingSessions(
            for: networkCapturePreferences.enabled
                ? networkCapturePreferences.snapshot.rules
                : [],
            startAuxiliary: false
        )
        activeConfigURL = nil
        if let activeProfileID {
            let activation = try await activateStoredProfile(
                activeProfileID,
                validator: try makeProfileValidator()
            )
            activeConfigURL = activation.configurationURL
        }
    }

    private func reconnectAfterBackupStateChange(
        shouldReconnect: Bool,
        shouldRestoreSystemProxy: Bool
    ) async throws {
        guard shouldReconnect else { return }
        guard activeConfigURL != nil else {
            throw AppModelError.profileActivationFailed(
                AppLocalization.string(
                    "The restored backup does not contain an active profile to reconnect."
                )
            )
        }
        guard await performConnect() else {
            throw AppModelError.profileActivationFailed(
                AppLocalization.string(
                    "The restored profile runtime could not be started."
                )
            )
        }
        if networkCapturePreferences.enabled {
            switch networkCaptureState {
            case let .on(revision)
                where revision == networkCapturePreferences.snapshot.revision:
                break
            case .requiresReboot:
                break
            case .on, .off, .waitingForConnection, .enabling,
                 .awaitingUserApproval, .disabling, .failed:
                throw AppModelError.profileActivationFailed(
                    AppLocalization.string(
                        "The restored App Routing configuration could not be activated."
                    )
                )
            }
        } else if shouldRestoreSystemProxy {
            await performEnableSystemProxy()
            guard systemProxyState == .on else {
                throw AppModelError.systemProxyRestoreFailed
            }
        }
    }

    private func performActivateProfile(
        _ id: ProfileID,
        force: Bool = false,
        rollbackSnapshot: StoredProfileSnapshot? = nil
    ) async throws {
        guard let profileStore, let profileLayout else {
            throw AppModelError.profileStoreUnavailable
        }

        if activeProfileID == id, activeConfigURL != nil, !force {
            return
        }

        let validator = try makeProfileValidator()
        // Source profile strategy is irrelevant in unified mode; the compiled
        // workspace activation below validates the generated runtime instead.
        if !unifiedConfigurationEnabled {
            try await validator.validate(
                configurationAt: profileLayout.configurationURL(for: id)
            )
        }

        let shouldReconnect = isConnected || isBusy
        let shouldRestoreSystemProxy = systemProxyEnabled
        if shouldReconnect {
            guard await performDisconnect() else {
                throw AppModelError.systemProxyRestoreFailed
            }
        }

        let previousProfileID = activeProfileID
        activeProfileID = id
        await refreshActiveProfileListenerPorts()
        let activation: RuntimeConfigurationActivation
        do {
            try await prepareProfileRoutingSessions(
                for: networkCapturePreferences.enabled
                    ? networkCapturePreferences.snapshot.rules
                    : [],
                startAuxiliary: false
            )
            activation = try await activateStoredProfile(
                id,
                validator: validator
            )
        } catch {
            activeProfileID = previousProfileID
            await refreshActiveProfileListenerPorts()
            try? await prepareProfileRoutingSessions(
                for: networkCapturePreferences.enabled
                    ? networkCapturePreferences.snapshot.rules
                    : [],
                startAuxiliary: false
            )
            if shouldReconnect {
                _ = await performConnect()
                if isConnected, shouldRestoreSystemProxy {
                    await performEnableSystemProxy()
                }
            }
            throw error
        }
        activeProfileID = activation.profileID
        await refreshActiveProfileListenerPorts()
        activeConfigURL = activation.configurationURL
        profiles = try await profileStore.profiles()
        errorMessage = nil

        if shouldReconnect {
            if await performConnect() {
                if shouldRestoreSystemProxy {
                    await performEnableSystemProxy()
                }
                return
            }

            let activationFailure = errorMessage ?? AppLocalization.string(
                "The new profile could not be started."
            )
            guard await stopCore() else {
                let stopFailure = errorMessage
                    ?? AppLocalization.string(
                        "The candidate proxy core could not be confirmed stopped."
                    )
                let message = "\(activationFailure) \(stopFailure)"
                errorMessage = message
                appendSupervisorLog(message)
                throw AppModelError.profileActivationFailed(message)
            }

            if let previousProfileID {
                do {
                    if let rollbackSnapshot,
                       rollbackSnapshot.metadata.id == previousProfileID {
                        try await profileStore.restoreProfile(
                            metadata: rollbackSnapshot.metadata,
                            configurationData: rollbackSnapshot.configurationData
                        )
                    }
                    activeProfileID = previousProfileID
                    await refreshActiveProfileListenerPorts()
                    try await prepareProfileRoutingSessions(
                        for: networkCapturePreferences.enabled
                            ? networkCapturePreferences.snapshot.rules
                            : [],
                        startAuxiliary: false
                    )
                    let rollback = try await activateStoredProfile(
                        previousProfileID,
                        validator: try makeProfileValidator()
                    )
                    activeProfileID = rollback.profileID
                    await refreshActiveProfileListenerPorts()
                    activeConfigURL = rollback.configurationURL
                    profiles = try await profileStore.profiles()
                    let restoredPreviousSession = await performConnect()
                    if restoredPreviousSession, shouldRestoreSystemProxy {
                        await performEnableSystemProxy()
                    }
                    let restoration = restoredPreviousSession
                        ? AppLocalization.string("The previous profile was restored.")
                        : AppLocalization.string(
                            "The previous profile also could not be restarted."
                        )
                    errorMessage = "\(activationFailure) \(restoration)"
                } catch {
                    errorMessage = AppLocalization.format(
                        "%@ Restoring the previous profile failed: %@",
                        activationFailure,
                        error.localizedDescription
                    )
                }
                appendSupervisorLog(errorMessage ?? activationFailure)
            } else {
                errorMessage = activationFailure
            }
            throw AppModelError.profileActivationFailed(errorMessage ?? activationFailure)
        }
    }

    private func compiledConfigurationForCurrentWorkspace() throws -> CompiledConfiguration? {
        guard unifiedConfigurationEnabled,
              let workspace = configurationDocument.currentWorkspace else {
            return nil
        }
        if let compiledConfiguration,
           compiledConfiguration.workspaceID == workspace.id,
           compiledConfiguration.workspaceRevision == workspace.revision {
            return compiledConfiguration
        }
        return try compileConfiguration(workspaceID: workspace.id)
    }

    private func activateStoredProfile(
        _ id: ProfileID,
        validator: any ProfileValidating
    ) async throws -> RuntimeConfigurationActivation {
        if !unifiedConfigurationEnabled {
            try await validateProfileRouteListenerTargets(
                profileRouteListeners(for: id)
            )
        }
        guard let profileStore else {
            throw AppModelError.profileStoreUnavailable
        }
        if unifiedConfigurationEnabled {
            guard let runtimeOverrideCoordinator, let compiledConfiguration else {
                throw AppModelError.profileStoreUnavailable
            }
            return try await runtimeOverrideCoordinator
                .activateCompiledConfiguration(
                    id,
                    baseConfiguration: compiledConfiguration.yaml,
                    overrides: compiledRuntimeOverrides(for: id),
                    networkExtensionListener: activeNetworkExtensionMihomoListener,
                    profileMixedListener: nil,
                    routeListeners: [],
                    allowedOutboundProxyNames: unifiedRuntimeProxyNames(),
                    in: profileStore,
                    validator: validator
                )
        }
        if let runtimeOverrideCoordinator {
            return try await runtimeOverrideCoordinator.activateProfile(
                id,
                overrides: effectiveRuntimeOverrides(for: id),
                networkExtensionListener: activeNetworkExtensionMihomoListener,
                profileMixedListener: activeProfileDedicatedMixedListener,
                routeListeners: profileRouteListeners(for: id),
                in: profileStore,
                validator: validator
            )
        }
        return try await profileStore.activateProfile(id, validator: validator)
    }

    private func activateStoredProfile(
        _ id: ProfileID,
        overrides: RuntimeOverrides,
        validator: any ProfileValidating
    ) async throws -> RuntimeConfigurationActivation {
        if !unifiedConfigurationEnabled {
            try await validateProfileRouteListenerTargets(
                profileRouteListeners(for: id)
            )
        }
        guard let profileStore, let runtimeOverrideCoordinator else {
            throw AppModelError.profileStoreUnavailable
        }
        var profileOverrides = overrides
        profileOverrides.ports.port = 0
        profileOverrides.ports.socksPort = 0
        profileOverrides.ports.mixedPort = id == activeProfileID
            ? profileRuntimePlan.defaultMixedPort
            : profileSessionSpec(for: id)?.mixedPort
        if unifiedConfigurationEnabled {
            guard let compiledConfiguration else {
                throw AppModelError.profileStoreUnavailable
            }
            return try await runtimeOverrideCoordinator
                .activateCompiledConfiguration(
                    id,
                    baseConfiguration: compiledConfiguration.yaml,
                    overrides: compiledRuntimeOverrides(for: id),
                    networkExtensionListener: activeNetworkExtensionMihomoListener,
                    profileMixedListener: nil,
                    routeListeners: [],
                    allowedOutboundProxyNames: unifiedRuntimeProxyNames(),
                    in: profileStore,
                    validator: validator
                )
        }
        return try await runtimeOverrideCoordinator.activateProfile(
            id,
            overrides: profileOverrides,
            networkExtensionListener: activeNetworkExtensionMihomoListener,
            profileMixedListener: activeProfileDedicatedMixedListener,
            routeListeners: profileRouteListeners(for: id),
            in: profileStore,
            validator: validator
        )
    }

    @discardableResult
    func applyRuntimeOverrides(
        _ overrides: RuntimeOverrides
    ) async throws -> RuntimeSettingsApplyOutcome {
        guard begin(.changeRuntimeSettings) else {
            throw AppModelError.operationInProgress
        }
        defer { end(.changeRuntimeSettings) }

        guard !unifiedConfigurationEnabled else {
            throw AppModelError.profileActivationFailed(
                AppLocalization.string("Configuration unavailable")
            )
        }

        var overrides = overrides
        // Keep the in-memory model byte-for-byte equivalent to the durable
        // mixed-only document written by the coordinator. Otherwise a later
        // failure appears to roll back in memory while a restart loads the
        // normalized port/socks-port zeros from disk.
        overrides.ports.port = 0
        overrides.ports.socksPort = 0

        guard let runtimeOverrideCoordinator, let profileStore else {
            throw AppModelError.profileStoreUnavailable
        }

        let previousOverrides = runtimeOverrides
        let previousRuntimePlan = profileRuntimePlan
        guard overrides != previousOverrides else {
            let outcome = RuntimeSettingsApplyOutcome.unchanged
            runtimeSettingsApplyState = .completed(outcome)
            return outcome
        }

        guard let activeProfileID else {
            runtimeSettingsApplyState = .saving
            do {
                try await runtimeOverrideCoordinator.save(overrides)
                runtimeOverrides = overrides
                errorMessage = nil
                let outcome = RuntimeSettingsApplyOutcome.saved
                runtimeSettingsApplyState = .completed(outcome)
                return outcome
            } catch {
                runtimeSettingsApplyState = .failed(error.localizedDescription)
                throw error
            }
        }

        var candidate = profileRuntimePlan
        let otherPorts = Set(candidate.sessions.map(\.mixedPort))
        let currentMixedPort = candidate.defaultMixedPort
        let requestedMixedPort: Int
        if let override = overrides.ports.mixedPort {
            requestedMixedPort = override
        } else if let sourceData = try? await profileStore.configurationData(
            for: activeProfileID
        ),
            let sourcePorts = try? RuntimeConfigurationComposer().listenerPorts(
                in: sourceData
            ),
            let sourceMixedPort = sourcePorts.mixedPort,
            (1...65_535).contains(sourceMixedPort),
            !otherPorts.contains(sourceMixedPort) {
            requestedMixedPort = sourceMixedPort
        } else {
            // “Use Profile” keeps the stable virtual Default Profile endpoint
            // when the source profile has no conflict-free Mixed port.
            requestedMixedPort = currentMixedPort
        }
        if otherPorts.contains(requestedMixedPort) {
            let error = ProfileRuntimePlanValidationError.duplicateMixedPort(
                requestedMixedPort
            )
            runtimeSettingsApplyState = .failed(error.localizedDescription)
            throw error
        }
        if requestedMixedPort != currentMixedPort,
           !mixedPortIsAvailableForStart(
               requestedMixedPort,
               profileID: activeProfileID
           ) {
            let error = AppModelError.profileMixedPortUnavailable(
                profileDisplayName(activeProfileID),
                requestedMixedPort
            )
            runtimeSettingsApplyState = .failed(error.localizedDescription)
            throw error
        }
        candidate.defaultMixedPort = requestedMixedPort
        candidate.primaryProfileID = activeProfileID
        try ProfileRuntimePlanValidator().validate(candidate)
        profileRuntimePlan = candidate

        let validator: any ProfileValidating
        do {
            runtimeSettingsApplyState = .validating
            validator = try makeProfileValidator()
            var validationOverrides = overrides
            validationOverrides.ports.port = 0
            validationOverrides.ports.socksPort = 0
            validationOverrides.ports.mixedPort = requestedMixedPort
            try await runtimeOverrideCoordinator.validateProfile(
                activeProfileID,
                overrides: validationOverrides,
                networkExtensionListener: activeNetworkExtensionMihomoListener,
                profileMixedListener: activeProfileDedicatedMixedListener,
                routeListeners: profileRouteListeners(for: activeProfileID),
                in: profileStore,
                validator: validator
            )
        } catch {
            profileRuntimePlan = previousRuntimePlan
            runtimeSettingsApplyState = .failed(error.localizedDescription)
            throw error
        }

        let shouldRestart = isConnected || isBusy
        let shouldRestoreSystemProxy = systemProxyEnabled
        if shouldRestart {
            runtimeSettingsApplyState = .restarting
            guard await performDisconnect() else {
                profileRuntimePlan = previousRuntimePlan
                let error = AppModelError.systemProxyRestoreFailed
                runtimeSettingsApplyState = .failed(error.localizedDescription)
                throw error
            }
        }

        runtimeOverrides = overrides
        do {
            let activation = try await activateStoredProfile(
                activeProfileID,
                overrides: overrides,
                validator: validator
            )
            self.activeProfileID = activation.profileID
            activeConfigURL = activation.configurationURL
            profiles = try await profileStore.profiles()

            if shouldRestart {
                runtimeSettingsApplyState = .restarting
                guard await performConnect() else {
                    throw AppModelError.profileActivationFailed(
                        errorMessage ?? AppLocalization.string(
                            "The updated runtime configuration could not be started."
                        )
                    )
                }
            }

            runtimeSettingsApplyState = .saving
            try await runtimeOverrideCoordinator.save(overrides)
            if profileRuntimePlan != previousRuntimePlan {
                try await profileRuntimePlanStore?.save(profileRuntimePlan)
            }

            if shouldRestart, shouldRestoreSystemProxy {
                await performEnableSystemProxy()
                guard systemProxyState == .on else {
                    throw AppModelError.profileActivationFailed(
                        errorMessage ?? AppLocalization.string(
                            "The macOS system proxy could not be restored after restarting the core."
                        )
                    )
                }
            }

            errorMessage = nil
            let outcome: RuntimeSettingsApplyOutcome = shouldRestart
                ? .savedAndRestarted
                : .saved
            runtimeSettingsApplyState = .completed(outcome)
            appendSupervisorLog(
                shouldRestart
                    ? "Runtime settings saved and the core restarted successfully."
                    : "Runtime settings saved."
            )
            return outcome
        } catch {
            profileRuntimePlan = previousRuntimePlan
            let primaryMessage = error.localizedDescription
            let restorationFailures = await Task { @MainActor [weak self] in
                guard let self else {
                    return [
                        AppLocalization.string(
                            "MClash closed before rollback completed."
                        )
                    ]
                }
                return await self.rollbackRuntimeOverrides(
                    previousOverrides,
                    previousRuntimePlan: previousRuntimePlan,
                    activeProfileID: activeProfileID,
                    shouldReconnect: shouldRestart,
                    shouldRestoreSystemProxy: shouldRestoreSystemProxy
                )
            }.value
            let restorationMessage = restorationFailures.isEmpty
                ? AppLocalization.string("The previous runtime settings were restored.")
                : AppLocalization.format(
                    "Restoring the previous runtime settings failed: %@",
                    restorationFailures.joined(separator: " ")
                )
            let message = "\(primaryMessage) \(restorationMessage)"
            errorMessage = message
            runtimeSettingsApplyState = .failed(message)
            appendSupervisorLog("Runtime settings update failed. \(message)")
            throw AppModelError.profileActivationFailed(message)
        }
    }

    @discardableResult
    func resetRuntimeOverrides() async throws -> RuntimeSettingsApplyOutcome {
        try await applyRuntimeOverrides(.empty)
    }

    @discardableResult
    func applyProfileRouteListeners(
        _ listeners: [ProfileRouteListenerSpec]
    ) async throws -> RuntimeSettingsApplyOutcome {
        guard begin(.changeRuntimeSettings) else {
            throw AppModelError.operationInProgress
        }
        defer { end(.changeRuntimeSettings) }
        guard !unifiedConfigurationEnabled else {
            throw AppModelError.profileActivationFailed(
                AppLocalization.string("Configuration unavailable")
            )
        }
        guard let activeProfileID,
              let profileStore,
              let runtimeOverrideCoordinator,
              let profileRuntimePlanStore else {
            throw AppModelError.profileStoreUnavailable
        }

        let previousPlan = profileRuntimePlan
        var candidate = previousPlan
        candidate.routeListeners = listeners
        for profileID in Set(listeners.filter(\.enabled).map(\.profileID)) {
            guard let index = candidate.sessions.firstIndex(where: {
                $0.profileID == profileID
            }) else {
                throw ProfileRuntimePlanValidationError
                    .routeListenerProfileMissing(profileID)
            }
            candidate.sessions[index].enabled = true
        }
        candidate.primaryProfileID = activeProfileID
        try ProfileRuntimePlanValidator().validate(candidate)
        guard candidate != previousPlan else {
            let outcome = RuntimeSettingsApplyOutcome.unchanged
            runtimeSettingsApplyState = .completed(outcome)
            return outcome
        }

        try await validateProfileRouteListenerTargets(listeners)
        let shouldRestart = isConnected || isBusy
        let shouldRestoreSystemProxy = systemProxyEnabled
        let currentlyOwnedPorts = shouldRestart
            ? Set(previousPlan.routeListeners.filter(\.enabled).map(\.port))
            : []
        for listener in listeners where listener.enabled {
            guard currentlyOwnedPorts.contains(listener.port)
                    || localPortProbe.isAvailableTCPAndUDP(port: listener.port)
            else {
                throw AppModelError.routeListenerPortUnavailable(
                    listener.name,
                    listener.port
                )
            }
        }

        profileRuntimePlan = candidate
        do {
            runtimeSettingsApplyState = .validating
            let validator = try makeProfileValidator()
            try await runtimeOverrideCoordinator.validateProfile(
                activeProfileID,
                overrides: effectiveRuntimeOverrides(for: activeProfileID),
                networkExtensionListener: activeNetworkExtensionMihomoListener,
                profileMixedListener: activeProfileDedicatedMixedListener,
                routeListeners: profileRouteListeners(for: activeProfileID),
                in: profileStore,
                validator: validator
            )

            if shouldRestart {
                runtimeSettingsApplyState = .restarting
                guard await performDisconnect() else {
                    throw AppModelError.profileActivationFailed(
                        AppLocalization.string(
                            "The running cores could not stop before the routing ports changed."
                        )
                    )
                }
            }

            let activation = try await activateStoredProfile(
                activeProfileID,
                validator: validator
            )
            activeConfigURL = activation.configurationURL
            if shouldRestart {
                guard await performConnect() else {
                    throw AppModelError.profileActivationFailed(
                        errorMessage ?? AppLocalization.string(
                            "The updated routing ports could not be started."
                        )
                    )
                }
            }

            runtimeSettingsApplyState = .saving
            try await profileRuntimePlanStore.save(candidate)
            if shouldRestart, shouldRestoreSystemProxy {
                await performEnableSystemProxy()
                guard systemProxyState == .on else {
                    throw AppModelError.profileActivationFailed(
                        errorMessage
                            ?? AppLocalization.string(
                                "The macOS system proxy could not be restored after restarting the cores."
                            )
                    )
                }
            }

            errorMessage = nil
            let outcome: RuntimeSettingsApplyOutcome = shouldRestart
                ? .savedAndRestarted
                : .saved
            runtimeSettingsApplyState = .completed(outcome)
            appendSupervisorLog(
                shouldRestart
                    ? "Routing ports saved and the cores restarted successfully."
                    : "Routing ports saved."
            )
            return outcome
        } catch {
            profileRuntimePlan = previousPlan
            let primaryMessage = error.localizedDescription
            let failures = await rollbackRuntimeOverrides(
                runtimeOverrides,
                previousRuntimePlan: previousPlan,
                activeProfileID: activeProfileID,
                shouldReconnect: shouldRestart,
                shouldRestoreSystemProxy: shouldRestoreSystemProxy
            )
            let recovery = failures.isEmpty
                ? AppLocalization.string("The previous routing ports were restored.")
                : AppLocalization.format(
                    "Restoring the previous routing ports failed: %@",
                    failures.joined(separator: " ")
                )
            let message = "\(primaryMessage) \(recovery)"
            errorMessage = message
            runtimeSettingsApplyState = .failed(message)
            appendSupervisorLog("Routing port update failed. \(message)")
            throw AppModelError.profileActivationFailed(message)
        }
    }

    private func validateProfileRouteListenerTargets(
        _ listeners: [ProfileRouteListenerSpec]
    ) async throws {
        for (profileID, profileListeners) in Dictionary(
            grouping: listeners.filter(\.enabled),
            by: \.profileID
        ) {
            let catalog = await profileRouteTargetCatalog(for: profileID)
            for listener in profileListeners {
                let targetIsAvailable: Bool
                switch listener.target {
                case .profileRules, .global:
                    targetIsAvailable = true
                case let .subRule(name):
                    targetIsAvailable = catalog.subRules.contains(name)
                case let .policyGroup(name):
                    targetIsAvailable = unifiedConfigurationEnabled
                        ? configurationDocument.proxyGroups.contains(where: { $0.name == name && $0.enabled })
                        : catalog.policyGroups.contains(name)
                case let .proxyNode(name):
                    targetIsAvailable = unifiedConfigurationEnabled
                        ? configurationDocument.nodes.contains(where: { ($0.userAlias ?? $0.displayName) == name && $0.enabled })
                        : (!catalog.isLive || catalog.proxyNodes.contains(name))
                }
                guard targetIsAvailable else {
                    throw AppModelError.routeListenerTargetUnavailable(
                        listener.name,
                        listener.target.presentationName
                    )
                }
            }
        }
    }

    private func rollbackRuntimeOverrides(
        _ previousOverrides: RuntimeOverrides,
        previousRuntimePlan: ProfileRuntimePlan,
        activeProfileID: ProfileID,
        shouldReconnect: Bool,
        shouldRestoreSystemProxy: Bool
    ) async -> [String] {
        guard let runtimeOverrideCoordinator, let profileStore else {
            return [AppModelError.profileStoreUnavailable.localizedDescription]
        }

        var failures: [String] = []
        do {
            try await runtimeOverrideCoordinator.save(previousOverrides)
        } catch {
            failures.append(
                AppLocalization.format(
                    "The previous override document could not be saved: %@",
                    error.localizedDescription
                )
            )
        }
        runtimeOverrides = previousOverrides
        profileRuntimePlan = previousRuntimePlan
        do {
            try await profileRuntimePlanStore?.save(previousRuntimePlan)
        } catch {
            failures.append(
                AppLocalization.format(
                    "The previous profile runtime plan could not be saved: %@",
                    error.localizedDescription
                )
            )
        }

        if isConnected || isBusy || hasSystemProxySnapshot {
            let disconnected = await performDisconnect()
            if !disconnected {
                failures.append(
                    AppLocalization.format(
                        "The candidate core could not be stopped safely: %@",
                        errorMessage ?? AppLocalization.string(
                            "No additional error was reported."
                        )
                    )
                )
                return failures
            }
        } else {
            guard await stopCore() else {
                failures.append(
                    AppLocalization.format(
                        "The candidate core could not be stopped safely: %@",
                        errorMessage ?? AppLocalization.string(
                            "No additional error was reported."
                        )
                    )
                )
                return failures
            }
        }

        do {
            let validator = try makeProfileValidator()
            let activation = try await activateStoredProfile(
                activeProfileID,
                overrides: previousOverrides,
                validator: validator
            )
            self.activeProfileID = activation.profileID
            activeConfigURL = activation.configurationURL
            profiles = try await profileStore.profiles()
        } catch {
            failures.append(
                AppLocalization.format(
                    "The previous runtime configuration could not be activated: %@",
                    error.localizedDescription
                )
            )
            return failures
        }

        if shouldReconnect {
            guard await performConnect() else {
                failures.append(
                    AppLocalization.format(
                        "The previous core session could not be restarted: %@",
                        errorMessage ?? AppLocalization.string(
                            "No additional error was reported."
                        )
                    )
                )
                return failures
            }
        }

        if shouldReconnect, shouldRestoreSystemProxy {
            await performEnableSystemProxy()
            if systemProxyState != .on {
                failures.append(
                    AppLocalization.format(
                        "The macOS system proxy could not be re-enabled: %@",
                        errorMessage ?? AppLocalization.string(
                            "No additional error was reported."
                        )
                    )
                )
            }
        }
        return failures
    }

    @discardableResult
    func refreshProfile(_ id: ProfileID) async -> Bool {
        guard begin(.refreshProfile(id)) else { return false }
        defer { end(.refreshProfile(id)) }

        switch await performRefreshProfile(id) {
        case .updated, .unchanged: return true
        case .failed: return false
        }
    }

    @discardableResult
    func refreshAllProfiles() async -> ProfileBatchUpdateReceipt? {
        guard begin(.refreshAllProfiles) else { return nil }
        defer { end(.refreshAllProfiles) }

        guard let profileStore else { return nil }
        do {
            let ids = try await profileStore.remoteProfileIDs()
            var updatedCount = 0
            var unchangedCount = 0
            var failedCount = 0
            for id in ids {
                try Task.checkCancellation()
                switch await performRefreshProfile(id) {
                case .updated: updatedCount += 1
                case .unchanged: unchangedCount += 1
                case .failed: failedCount += 1
                }
            }
            profileBatchUpdateReceipt = ProfileBatchUpdateReceipt(
                completedAt: Date(),
                updatedCount: updatedCount,
                unchangedCount: unchangedCount,
                failedCount: failedCount
            )
            return profileBatchUpdateReceipt
        } catch is CancellationError {
            return nil
        } catch {
            recordOperationFailure(error, context: "Subscription refresh")
            return nil
        }
    }

    private func performRefreshProfile(_ id: ProfileID) async -> ProfileRefreshOperationOutcome {

        guard let profileStore else { return .failed }
        let subscriptionURL = profiles.first(where: { $0.id == id }).flatMap { profile -> URL? in
            guard case let .remote(remote) = profile.origin else { return nil }
            return remote.url
        }
        let rollbackSnapshot: StoredProfileSnapshot?
        let refreshAffectsRunningSession = activeProfileID == id
            || (
                profileSessionSpec(for: id)?.enabled == true
                    && (isConnected || isBusy)
            )
        if refreshAffectsRunningSession {
            do {
                rollbackSnapshot = StoredProfileSnapshot(
                    metadata: try await profileStore.metadata(for: id),
                    configurationData: try await profileStore.configurationData(for: id)
                )
            } catch {
                recordOperationFailure(error, context: "Subscription snapshot")
                return .failed
            }
        } else {
            rollbackSnapshot = nil
        }

        var remoteRefreshCompleted = false
        do {
            let result = try await profileStore.refreshRemoteProfile(
                id,
                validator: try makeProfileValidator()
            )
            remoteRefreshCompleted = true
            profiles = try await profileStore.profiles()
            await synchronizeConfigurationSources()
            if activeProfileID == id, case .updated = result {
                try await performActivateProfile(
                    id,
                    force: true,
                    rollbackSnapshot: rollbackSnapshot
                )
            } else if case .updated = result,
                      profileSessionSpec(for: id)?.enabled == true,
                      isConnected || isBusy {
                try await prepareProfileRoutingSessions(
                    for: networkCapturePreferences.enabled
                        ? networkCapturePreferences.snapshot.rules
                        : [],
                    startAuxiliary: true
                )
            }
            return switch result {
            case .updated: .updated
            case .notModified: .unchanged
            }
        } catch {
            if let rollbackSnapshot, remoteRefreshCompleted {
                do {
                    try await profileStore.restoreProfile(
                        metadata: rollbackSnapshot.metadata,
                        configurationData: rollbackSnapshot.configurationData
                    )
                    profiles = try await profileStore.profiles()
                    if activeProfileID != id,
                       profileSessionSpec(for: id)?.enabled == true,
                       isConnected || isBusy {
                        try await prepareProfileRoutingSessions(
                            for: networkCapturePreferences.enabled
                                ? networkCapturePreferences.snapshot.rules
                                : [],
                            startAuxiliary: true
                        )
                    }
                } catch {
                    appendSupervisorLog(
                        "Subscription rollback failed: \(error.localizedDescription)"
                    )
                }
            } else if let refreshedProfiles = try? await profileStore.profiles() {
                // A fetch or validation failure is already transactional in
                // ProfileStore. Reload its persisted retry metadata instead of
                // restoring the pre-attempt snapshot and erasing backoff state.
                profiles = refreshedProfiles
            }
            let message = redactedSubscriptionMessage(
                error.localizedDescription,
                url: subscriptionURL
            )
            errorMessage = message
            appendSupervisorLog("Subscription refresh failed: \(message)")
            return .failed
        }
    }

    private func startSubscriptionUpdateScheduler() {
        subscriptionUpdateTask?.cancel()
        subscriptionUpdateTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.refreshDueProfiles()
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(15 * 60))
                } catch {
                    return
                }
                await self.refreshDueProfiles()
            }
        }
    }

    private func refreshDueProfiles() async {
        guard !shutdownInProgress,
              let profileStore,
              begin(.refreshAllProfiles) else { return }
        defer { end(.refreshAllProfiles) }

        do {
            let ids = try await profileStore.remoteProfileIDsDueForAutomaticUpdate(at: Date())
            for id in ids {
                try Task.checkCancellation()
                _ = await performRefreshProfile(id)
            }
        } catch is CancellationError {
            return
        } catch {
            appendSupervisorLog("Automatic subscription refresh failed: \(error.localizedDescription)")
        }
    }

    func removeProfile(_ id: ProfileID) async {
        guard begin(.removeProfile(id)) else { return }
        defer { end(.removeProfile(id)) }

        guard let profileStore, let profileLayout else { return }
        do {
            if let reason = profileRemovalBlockReason(for: id) {
                throw AppModelError.profileActivationFailed(reason)
            }
            try await removeStoredProfileAndRuntimeState(
                id,
                nextPrimaryProfileID: activeProfileID,
                profileStore: profileStore,
                profileLayout: profileLayout
            )
            errorMessage = nil
        } catch {
            recordOperationFailure(error, context: "Profile removal")
        }
    }

    func profileRemovalBlockReason(for profileID: ProfileID) -> String? {
        if profileID == activeProfileID {
            return AppLocalization.string(
                "Activate another default profile before deleting this one."
            )
        }
        if networkCapturePreferences.snapshot.rules.contains(where: { rule in
            guard rule.enabled,
                  case let .mihomo(route) = rule.action,
                  let target = route.routingProfileID else { return false }
            return target.uuid == profileID.rawValue
        }) {
            return AppLocalization.string(
                "Change or disable the App Routing rules that use this profile before deleting it."
            )
        }
        if profileSessionSpec(for: profileID)?.enabled == true {
            return AppLocalization.string(
                "Turn off this profile's App Routing session before deleting it."
            )
        }
        return nil
    }

    func toggleConnection() async {
        guard begin(.connection) else { return }
        defer { end(.connection) }

        if isConnected || isBusy {
            setNetworkEnvironmentRecoveryArmed(false)
            if await performDisconnect() {
                setConnectionDesiredOnLaunch(false)
            }
        } else {
            let connected = await performConnect()
            if connected {
                setConnectionDesiredOnLaunch(true)
            }
            if connected, autoEnableSystemProxy {
                await enableSystemProxyAfterConnect()
            }
        }
    }

    func connect() async {
        guard begin(.connection) else { return }
        defer { end(.connection) }
        let connected = await performConnect()
        if connected {
            setConnectionDesiredOnLaunch(true)
        }
        if connected, autoEnableSystemProxy {
            await enableSystemProxyAfterConnect()
        }
    }

    func disconnect() async {
        guard begin(.connection) else { return }
        defer { end(.connection) }
        setNetworkEnvironmentRecoveryArmed(false)
        if await performDisconnect() {
            setConnectionDesiredOnLaunch(false)
        }
    }

    func restartConnection() async {
        guard begin(.connection) else { return }
        defer { end(.connection) }

        let shouldEnableSystemProxy = isConnected ? systemProxyEnabled : autoEnableSystemProxy
        guard await performDisconnect() else { return }
        let connected = await performConnect()
        if connected, shouldEnableSystemProxy {
            await enableSystemProxyAfterConnect()
        }
    }

    @discardableResult
    private func performConnect() async -> Bool {
        guard !shutdownInProgress else { return false }
        if isConnected, controllerIsReady {
            return true
        }
        guard activeConfigURL != nil else {
            selection = .profiles
            errorMessage = AppLocalization.string(
                "Add or select a profile before connecting."
            )
            return false
        }

        do {
            errorMessage = nil
            try await prepareProfileRoutingSessions(
                for: networkCapturePreferences.enabled
                    ? networkCapturePreferences.snapshot.rules
                    : [],
                startAuxiliary: false
            )
            if unifiedConfigurationEnabled, runtimeOverrideCoordinator == nil {
                throw AppModelError.profileStoreUnavailable
            }
            try await repairManagedMixedPortCollision()
            if let activeProfileID, runtimeOverrideCoordinator != nil {
                let activation = try await activateStoredProfile(
                    activeProfileID,
                    validator: try makeProfileValidator()
                )
                activeConfigURL = activation.configurationURL
            }
            guard let activeConfigURL, let activeProfileID else {
                throw AppModelError.profileStoreUnavailable
            }
            let primaryConfigurationData = try Data(
                contentsOf: activeConfigURL,
                options: .mappedIfSafe
            )
            let primaryBoundPorts = try RuntimeConfigurationComposer()
                .boundListenerPorts(in: primaryConfigurationData)
            let primarySourceBoundPorts = try await primarySourceBoundListenerPorts(
                profileID: activeProfileID
            )
            let managedNonPrimaryPorts = Set(
                profileRuntimePlan.enabledSessions.compactMap {
                    $0.profileID == activeProfileID ? nil : $0.mixedPort
                }
                + networkExtensionProfileListeners.flatMap { _, listener in
                    listener.routeListeners.map { Int($0.port) }
                }
            )
            let conflictingPorts = primarySourceBoundPorts.intersection(
                managedNonPrimaryPorts
            )
            guard conflictingPorts.isEmpty else {
                throw AppModelError.primaryListenerPortConflict(
                    conflictingPorts.sorted()
                )
            }
            let binaryURL = try binaryLocator.locate()
            let secret = try secretStore.loadOrCreate()
            let homeDirectory = try coreHomeDirectory()
            try geoDataInstaller.installIfNeeded(into: homeDirectory)
            let controllerPort = try availableTCPPort(
                excluding: Set(
                    profileRuntimePlan.enabledSessions.map(\.mixedPort)
                        + networkExtensionProfileListeners.values.flatMap {
                            $0.routeListeners.map { Int($0.port) }
                        }
                ).union(primaryBoundPorts)
            )
            let configuration = CoreLaunchConfiguration(
                binaryURL: binaryURL,
                homeDirectory: homeDirectory,
                configURL: activeConfigURL,
                controllerPort: UInt16(controllerPort),
                secret: secret
            )
            guard !shutdownInProgress else { throw CancellationError() }
            try await supervisor.start(configuration)
            let state = await supervisor.state()
            coreState = state
            if case let .running(session) = state {
                await controllerDidStart(session)
            }
            guard isConnected, controllerIsReady else {
                await cleanupFailedConnectionAttempt()
                return false
            }
            guard !shutdownInProgress else { throw CancellationError() }
            try await prepareProfileRoutingSessions(
                for: networkCapturePreferences.enabled
                    ? networkCapturePreferences.snapshot.rules
                    : [],
                startAuxiliary: true
            )
            if isConnected, controllerIsReady, networkCapturePreferences.enabled {
                await performNetworkCaptureActivation()
            }
            let connected = isConnected && controllerIsReady
            if connected {
                if let port = localMixedListenerPort {
                    verifiedMClashMixedPorts[
                        activeProfileID,
                        default: []
                    ].insert(port)
                }
                if let dedicatedPort = activeProfileDedicatedMixedListener.map({
                    Int($0.port)
                }) {
                    verifiedMClashMixedPorts[
                        activeProfileID,
                        default: []
                    ].insert(dedicatedPort)
                }
                setNetworkEnvironmentRecoveryArmed(true)
                return true
            }
            await cleanupFailedConnectionAttempt()
            return false
        } catch is CancellationError {
            await cleanupFailedConnectionAttempt()
            return false
        } catch {
            await cleanupFailedConnectionAttempt()
            errorMessage = error.localizedDescription
            appendSupervisorLog("Connection failed: \(error.localizedDescription)")
            return false
        }
    }

    @discardableResult
    private func cleanupFailedConnectionAttempt() async -> Bool {
        let auxiliaryStops = await coreFleet.stopAll()
        auxiliaryCoreStates = await coreFleet.states()
        let auxiliaryStopped = auxiliaryStops.values.allSatisfy({ $0 })
        if !auxiliaryStopped {
            appendSupervisorLog(
                "Connection cleanup could not confirm every auxiliary profile core stopped."
            )
        }

        let primaryStopped = await supervisor.stop()
        coreState = await supervisor.state()
        if primaryStopped {
            stopControllerStreams()
        } else {
            appendSupervisorLog(
                "Connection cleanup could not confirm the primary core stopped."
            )
        }
        return auxiliaryStopped && primaryStopped
    }

    @discardableResult
    private func performDisconnect() async -> Bool {
        shouldReenableSystemProxyAfterCrash = false
        if networkCaptureIsActive {
            guard await performNetworkCaptureDeactivation() else { return false }
        }
        if systemProxyEnabled || hasSystemProxySnapshot {
            guard await performDisableSystemProxy() else { return false }
        }
        let auxiliaryStops = await coreFleet.stopAll()
        auxiliaryCoreStates = await coreFleet.states()
        guard auxiliaryStops.values.allSatisfy({ $0 }) else {
            errorMessage = AppLocalization.string(
                "One or more auxiliary profile cores could not be confirmed stopped."
            )
            return false
        }
        return await stopCore()
    }

    @discardableResult
    private func stopCore() async -> Bool {
        let stopped = await supervisor.stop()
        coreState = await supervisor.state()
        guard stopped else {
            if case let .failed(message) = coreState {
                errorMessage = message
            } else {
                errorMessage = AppLocalization.string(
                    "The proxy core could not be confirmed stopped."
                )
            }
            return false
        }
        stopControllerStreams()
        return true
    }

    func setMode(_ mode: String) async {
        if unifiedConfigurationEnabled,
           let configurationMode = ConfigurationRoutingMode(
               rawValue: mode.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
           ) {
            do {
                _ = try await setConfigurationRoutingMode(configurationMode)
            } catch {
                errorMessage = error.localizedDescription
            }
            return
        }
        guard begin(.changeMode) else { return }
        pendingMode = mode
        defer {
            pendingMode = nil
            end(.changeMode)
        }

        guard let apiClient else { return }
        let generation = controllerGeneration
        invalidateProxyRefreshes()
        do {
            try await apiClient.patchConfig(MihomoConfigPatch(mode: mode))
            let config = try await apiClient.fetchConfig()
            guard generation == controllerGeneration, isConnected else { return }
            runtimeConfig = config
            await closeConnectionsAfterRoutingChange(using: apiClient, generation: generation)
        } catch {
            guard generation == controllerGeneration else { return }
            recordOperationFailure(error, context: "Routing mode change")
        }
    }

    /// Persists and applies the routing mode of a MClash workspace. The live
    /// controller is patched in place so switching Rule/Global/Direct does not
    /// require replacing the imported source or rebuilding the node catalog.
    /// A candidate is compiled before any durable mutation; if the controller
    /// rejects the mode, the workspace document remains untouched.
    @discardableResult
    func setConfigurationRoutingMode(
        _ mode: ConfigurationRoutingMode,
        workspaceID requestedWorkspaceID: WorkspaceID? = nil
    ) async throws -> Bool {
        guard begin(.changeRuntimeSettings) else {
            throw ConfigurationAutomationError.operationInProgress
        }
        defer { end(.changeRuntimeSettings) }

        var candidate = configurationDocument
        guard let targetID = requestedWorkspaceID
                ?? candidate.currentWorkspace?.id,
              let workspaceIndex = candidate.workspaces.firstIndex(where: {
                  $0.id == targetID
              }) else {
            throw ConfigurationAutomationError.invalidInput(
                "The selected MClash configuration does not exist"
            )
        }
        let previousMode = candidate.workspaces[workspaceIndex].routingMode
        let previousGlobalTarget = candidate.workspaces[workspaceIndex]
            .globalProxyGroupID
        let enabledGroup = candidate.proxyGroups.first(where: { group in
            group.enabled
                && candidate.workspaces[workspaceIndex].proxyGroupIDs.contains(group.id)
        })
        if mode == .global,
           candidate.workspaces[workspaceIndex].globalProxyGroupID == nil {
            candidate.workspaces[workspaceIndex].globalProxyGroupID = enabledGroup?.id
        }
        candidate.workspaces[workspaceIndex].routingMode = mode
        if candidate.workspaces[workspaceIndex].routingMode != previousMode
            || candidate.workspaces[workspaceIndex].globalProxyGroupID
                != previousGlobalTarget {
            candidate.workspaces[workspaceIndex].revision += 1
        }

        // Validate every workspace because the shared document is durable and
        // a mode change must not make a secondary configuration unreadable.
        let compiledTarget = try ConfigurationCompiler().compile(
            document: candidate,
            workspaceID: targetID
        )
        for workspace in candidate.workspaces where workspace.id != targetID {
            _ = try ConfigurationCompiler().compile(
                document: candidate,
                workspaceID: workspace.id
            )
        }

        let isCurrentWorkspace = unifiedConfigurationEnabled
            && candidate.currentWorkspaceID == targetID
            && isConnected
            && controllerIsReady
        let generation = controllerGeneration
        let previousLiveMode = runtimeConfig?.mode.lowercased()
        if isCurrentWorkspace, let apiClient {
            pendingMode = mode.rawValue
            defer { pendingMode = nil }
            invalidateProxyRefreshes()
            do {
                try await apiClient.patchConfig(
                    MihomoConfigPatch(mode: mode.rawValue)
                )
                if mode == .global,
                   let targetGroupID = candidate.workspaces[workspaceIndex]
                        .globalProxyGroupID,
                   let targetName = candidate.proxyGroups.first(where: {
                       $0.id == targetGroupID && $0.enabled
                   })?.name {
                    // Mihomo exposes GLOBAL as an implicit selector. The
                    // explicit generated GLOBAL group mirrors this target but
                    // the controller selection is the authoritative live state.
                    try await apiClient.selectProxy(
                        group: "GLOBAL",
                        proxy: targetName
                    )
                }
                let liveConfig = try await apiClient.fetchConfig()
                guard generation == controllerGeneration, isConnected else {
                    throw AppModelError.streamEnded("Routing mode")
                }
                runtimeConfig = liveConfig
                await closeConnectionsAfterRoutingChange(
                    using: apiClient,
                    generation: generation
                )
            } catch {
                // Best-effort restoration keeps the in-memory and live mode
                // aligned if persistence or a later request fails.
                if let previousLiveMode,
                   previousLiveMode != mode.rawValue,
                   generation == controllerGeneration {
                    try? await apiClient.patchConfig(
                        MihomoConfigPatch(mode: previousLiveMode)
                    )
                }
                throw error
            }
        }

        do {
            try await persistConfigurationDocument(candidate)
        } catch {
            // Storage failure must not leave the live controller on a mode the
            // durable document could not record. Restore both mode and the
            // previous GLOBAL selection when the live patch already landed.
            if isCurrentWorkspace, let apiClient,
               generation == controllerGeneration {
                if let previousLiveMode,
                   previousLiveMode != mode.rawValue {
                    try? await apiClient.patchConfig(
                        MihomoConfigPatch(mode: previousLiveMode)
                    )
                }
                if previousMode == .global,
                   let previousID = previousGlobalTarget,
                   let previousName = configurationDocument.proxyGroups.first(where: {
                       $0.id == previousID && $0.enabled
                   })?.name {
                    try? await apiClient.selectProxy(
                        group: "GLOBAL",
                        proxy: previousName
                    )
                }
                if let restored = try? await apiClient.fetchConfig() {
                    runtimeConfig = restored
                }
            }
            throw error
        }
        if candidate.currentWorkspaceID == targetID {
            compiledConfiguration = compiledTarget
        }
        return true
    }

    @discardableResult
    func setConfigurationGlobalProxyGroup(
        _ groupID: ProxyGroupID,
        workspaceID requestedWorkspaceID: WorkspaceID? = nil
    ) async throws -> Bool {
        guard begin(.changeRuntimeSettings) else {
            throw ConfigurationAutomationError.operationInProgress
        }
        defer { end(.changeRuntimeSettings) }
        var candidate = configurationDocument
        guard let targetID = requestedWorkspaceID ?? candidate.currentWorkspace?.id,
              let workspaceIndex = candidate.workspaces.firstIndex(where: {
                  $0.id == targetID
              }),
              candidate.workspaces[workspaceIndex].proxyGroupIDs.contains(groupID),
              candidate.proxyGroups.contains(where: { $0.id == groupID && $0.enabled }) else {
            throw ConfigurationAutomationError.invalidInput(
                "Choose an enabled strategy group in the selected MClash configuration"
            )
        }
        let previousID = candidate.workspaces[workspaceIndex].globalProxyGroupID
        guard previousID != groupID else { return true }
        candidate.workspaces[workspaceIndex].globalProxyGroupID = groupID
        candidate.workspaces[workspaceIndex].revision += 1
        _ = try ConfigurationCompiler().compile(
            document: candidate,
            workspaceID: targetID
        )
        let isCurrentWorkspace = unifiedConfigurationEnabled
            && candidate.currentWorkspaceID == targetID
            && isConnected
            && controllerIsReady
        let generation = controllerGeneration
        if isCurrentWorkspace, let apiClient {
            guard candidate.workspaces[workspaceIndex].routingMode == .global else {
                try await persistConfigurationDocument(candidate)
                return true
            }
            guard let targetName = candidate.proxyGroups.first(where: {
                $0.id == groupID && $0.enabled
            })?.name else {
                throw ConfigurationAutomationError.invalidInput(
                    "The selected Global exit group is unavailable"
                )
            }
            do {
                try await apiClient.selectProxy(
                    group: "GLOBAL",
                    proxy: targetName
                )
                guard generation == controllerGeneration, isConnected else {
                    throw AppModelError.streamEnded("Global exit")
                }
                await closeConnectionsAfterRoutingChange(
                    using: apiClient,
                    generation: generation
                )
            } catch {
                // The controller selection is ephemeral; the durable document
                // is intentionally not changed when it cannot be applied.
                _ = previousID
                throw error
            }
        }
        do {
            try await persistConfigurationDocument(candidate)
        } catch {
            if isCurrentWorkspace, let apiClient,
               generation == controllerGeneration,
               let previousID,
               let previousName = configurationDocument.proxyGroups.first(where: {
                   $0.id == previousID && $0.enabled
               })?.name {
                try? await apiClient.selectProxy(
                    group: "GLOBAL",
                    proxy: previousName
                )
            }
            throw error
        }
        if candidate.currentWorkspaceID == targetID {
            compiledConfiguration = try? ConfigurationCompiler().compile(
                document: candidate,
                workspaceID: targetID
            )
        }
        return true
    }

    func selectProxy(group: String, proxy: String) async -> Bool {
        guard begin(.selectProxy(group)) else { return false }
        pendingProxySelections[group] = proxy
        defer {
            pendingProxySelections[group] = nil
            end(.selectProxy(group))
        }

        guard let apiClient,
              let groupModel = proxiesByName[group],
              groupModel.groupBehavior?.supportsSelectionUpdate == true else {
            errorMessage = AppLocalization.string(
                "This proxy group is selected automatically for each connection."
            )
            return false
        }
        let generation = controllerGeneration
        invalidateProxyRefreshes()
        do {
            try await apiClient.selectProxy(group: group, proxy: proxy)
            await refreshProxyGroups(generation: generation)
            guard generation == controllerGeneration, isConnected else { return false }
            await closeConnectionsAfterRoutingChange(using: apiClient, generation: generation)
            return generation == controllerGeneration && isConnected
        } catch {
            guard generation == controllerGeneration else { return false }
            recordOperationFailure(error, context: "Proxy selection")
            return false
        }
    }

    func clearProxyOverride(group: String) async -> Bool {
        guard begin(.clearProxyOverride(group)) else { return false }
        defer { end(.clearProxyOverride(group)) }

        guard let apiClient,
              let groupModel = proxiesByName[group],
              groupModel.groupBehavior?.supportsClearingOverride == true else {
            errorMessage = AppLocalization.string(
                "This proxy group does not have an automatic override to clear."
            )
            return false
        }
        let generation = controllerGeneration
        invalidateProxyRefreshes()
        do {
            try await apiClient.clearProxyOverride(group: group)
            await refreshProxyGroups(generation: generation)
            guard generation == controllerGeneration, isConnected else { return false }
            await closeConnectionsAfterRoutingChange(using: apiClient, generation: generation)
            return generation == controllerGeneration && isConnected
        } catch {
            guard generation == controllerGeneration else { return false }
            recordOperationFailure(error, context: "Restore automatic proxy selection")
            return false
        }
    }

    func measureDelay(proxy: String, group: String? = nil) async -> Int? {
        guard begin(.measureDelay(proxy)) else { return nil }
        defer { end(.measureDelay(proxy)) }

        guard let apiClient,
              let target = delayTarget(forProxy: proxy, group: group) else {
            return nil
        }
        let expectedStatus = expectedDelayStatus(forProxy: proxy, group: group)
        let generation = controllerGeneration
        invalidateProxyRefreshes()
        do {
            let delay = try await apiClient.measureDelay(
                proxy: proxy,
                targetURL: target,
                expectedStatus: expectedStatus
            )
            guard generation == controllerGeneration, isConnected else { return nil }
            invalidateProxyRefreshes()
            proxyDelays[proxy] = delay
            if let group {
                contextualProxyDelays[
                    ProxyDelayContextKey(group: group, proxy: proxy, targetURL: target)
                ] = delay
            }
            return delay
        } catch {
            guard generation == controllerGeneration else { return nil }
            recordOperationFailure(error, context: "Latency test")
            return nil
        }
    }

    func measureGroupDelays(group: String) async {
        guard begin(.measureGroupDelay(group)) else { return }
        defer { end(.measureGroupDelay(group)) }

        guard let apiClient,
              let groupModel = proxiesByName[group] else {
            return
        }
        let target = delayTarget(for: groupModel) ?? defaultDelayTarget
        let expectedStatus = normalizedExpectedStatus(groupModel.expectedStatus)
        let generation = controllerGeneration
        var seen = Set<String>()
        let members = groupModel.all.filter { seen.insert($0).inserted }
        invalidateProxyRefreshes()

        // Alpha's GET /group/{name}/delay endpoint clears fixed selections on
        // URLTest and Fallback groups. Measure members directly so a read-only
        // latency action never changes the user's routing preference.
        var delays: [String: Int] = [:]
        let maximumConcurrentRequests = 8
        for batchStart in stride(from: 0, to: members.count, by: maximumConcurrentRequests) {
            guard !Task.isCancelled else { return }
            let batchEnd = min(batchStart + maximumConcurrentRequests, members.count)
            let batch = Array(members[batchStart..<batchEnd])
            let batchDelays = await withTaskGroup(
                of: (String, Int?).self,
                returning: [String: Int].self
            ) { taskGroup in
                for proxy in batch {
                    taskGroup.addTask {
                        let delay = try? await apiClient.measureDelay(
                            proxy: proxy,
                            targetURL: target,
                            expectedStatus: expectedStatus
                        )
                        return (proxy, delay)
                    }
                }

                var measured: [String: Int] = [:]
                for await (proxy, delay) in taskGroup {
                    if let delay { measured[proxy] = delay }
                }
                return measured
            }
            delays.merge(batchDelays) { _, new in new }
        }

        guard generation == controllerGeneration, isConnected else { return }
        invalidateProxyRefreshes()
        proxyDelays.merge(delays) { _, new in new }
        for (proxy, delay) in delays {
            contextualProxyDelays[
                ProxyDelayContextKey(group: group, proxy: proxy, targetURL: target)
            ] = delay
        }
        if delays.isEmpty, !members.isEmpty {
            recordOperationFailure(MihomoAPIError.emptyResponse, context: "Group latency test")
        }
    }

    /// Every imported real Profile is a selectable Proxies workspace,
    /// regardless of whether its dedicated runtime is currently available.
    var profileProxyWorkspaceProfiles: [ProfileMetadata] {
        profiles
    }

    func profileRouteTargetCatalog(
        for profileID: ProfileID
    ) async -> ProfileRouteTargetCatalog {
        var catalog = ProfileRouteTargetCatalog.empty(profileID: profileID)
        if let profileStore,
           let data = try? await profileStore.configurationData(for: profileID) {
            catalog = ProfileRouteTargetCatalogReader().read(
                profileID: profileID,
                data: data
            )
        }

        let snapshot = profileProxyWorkspaceStates[profileID]?.snapshot
        guard let snapshot else { return catalog }

        let groups = snapshot.topology.groupOrder
        let nodes = snapshot.topology.vertices.values.compactMap { vertex -> String? in
            if case .endpoint = vertex.kind { return vertex.name }
            return nil
        }.sorted(by: proxyStableNameComesBefore)
        return ProfileRouteTargetCatalog(
            profileID: profileID,
            subRules: catalog.subRules,
            policyGroups: groups,
            proxyNodes: nodes,
            isLive: true
        )
    }

    /// Returns cached controller data without starting or enabling a Profile.
    /// Auxiliary Profiles whose dedicated port is closed are always surfaced
    /// as unavailable, even if an older snapshot remains in memory.
    func profileProxyWorkspaceState(
        for profileID: ProfileID
    ) -> ProfileProxyWorkspaceState {
        guard profiles.contains(where: { $0.id == profileID }) else {
            return .unavailable(.profileNotFound)
        }
        if profileProxyControllerResolverOverride == nil,
           profileID != activeProfileID,
           profileSessionSpec(for: profileID)?.enabled != true {
            return .unavailable(.dedicatedPortDisabled(
                port: profileSessionSpec(for: profileID)?.mixedPort
            ))
        }
        return profileProxyWorkspaceStates[profileID] ?? .idle
    }

    func pendingProxySelection(
        profileID: ProfileID,
        group: String
    ) -> String? {
        pendingProfileProxySelections[
            ProfileProxySelectionKey(profileID: profileID, group: group)
        ]
    }

    /// Fetches a complete, Profile-scoped Proxies snapshot from an already
    /// running controller. This method never starts a core or opens a port.
    @discardableResult
    func refreshProxyWorkspace(
        for profileID: ProfileID
    ) async -> ProfileProxyWorkspaceState {
        let operation = Operation.refreshProfileProxyWorkspace(profileID)
        guard begin(operation) else {
            return profileProxyWorkspaceState(for: profileID)
        }
        defer { end(operation) }

        let previous = profileProxyWorkspaceStates[profileID]?.snapshot
        let revision = nextProfileProxyWorkspaceRevision(for: profileID)
        profileProxyWorkspaceStates[profileID] = .loading(previous: previous)

        switch await resolveProfileProxyController(for: profileID) {
        case let .unavailable(reason):
            guard profileProxyWorkspaceRevision(
                for: profileID,
                matches: revision
            ) else {
                return profileProxyWorkspaceState(for: profileID)
            }
            let state = ProfileProxyWorkspaceState.unavailable(reason)
            profileProxyWorkspaceStates[profileID] = state
            return state

        case let .available(client):
            do {
                let profileStructure = await loadProxyProfileStructure(
                    for: profileID
                )
                async let configRequest = client.fetchConfig()
                async let proxiesRequest = client.fetchProxies()
                let (config, collection) = try await (
                    configRequest,
                    proxiesRequest
                )
                try Task.checkCancellation()
                guard profileProxyWorkspaceRevision(
                    for: profileID,
                    matches: revision
                ) else {
                    return profileProxyWorkspaceState(for: profileID)
                }
                let snapshot = ProfileProxyWorkspaceSnapshotBuilder().build(
                    profileID: profileID,
                    runtimeConfig: config,
                    collection: collection,
                    profileStructure: profileStructure,
                    measuredDelays: profileProxyMeasuredDelays[profileID] ?? [:]
                )
                profileProxyWorkspaceStates[profileID] = .ready(snapshot)
                synchronizeLegacyProxyStateIfNeeded(snapshot)
                return .ready(snapshot)
            } catch is CancellationError {
                guard profileProxyWorkspaceRevision(
                    for: profileID,
                    matches: revision
                ) else {
                    return profileProxyWorkspaceState(for: profileID)
                }
                let state = ProfileProxyWorkspaceState.idle
                profileProxyWorkspaceStates[profileID] = state
                return state
            } catch {
                guard profileProxyWorkspaceRevision(
                    for: profileID,
                    matches: revision
                ) else {
                    return profileProxyWorkspaceState(for: profileID)
                }
                let state = ProfileProxyWorkspaceState.failed(
                    message: error.localizedDescription,
                    previous: previous
                )
                profileProxyWorkspaceStates[profileID] = state
                recordOperationFailure(
                    error,
                    context: "Profile proxy refresh"
                )
                return state
            }
        }
    }

    /// Changes one Profile's runtime mode without changing another Profile's
    /// controller or cached workspace.
    @discardableResult
    func setMode(_ mode: String, profileID: ProfileID) async -> Bool {
        let operation = Operation.changeProfileMode(profileID)
        guard begin(operation) else { return false }
        defer { end(operation) }
        guard case let .available(client) = await resolveProfileProxyController(
            for: profileID
        ) else {
            await refreshProxyWorkspace(for: profileID)
            return false
        }
        do {
            try await client.patchConfig(MihomoConfigPatch(mode: mode))
            await closeProfileConnectionsAfterRoutingChange(
                using: client,
                profileID: profileID
            )
            let state = await refreshProxyWorkspace(for: profileID)
            return state.snapshot?.runtimeConfig.mode.caseInsensitiveCompare(mode)
                == .orderedSame
        } catch {
            failProfileProxyWorkspace(
                profileID,
                error: error,
                context: "Profile routing mode change"
            )
            return false
        }
    }

    /// Selects a node in one Profile. The operation identity contains both
    /// Profile and group, so same-named groups in other Profiles stay
    /// independent.
    @discardableResult
    func selectProxy(
        profileID: ProfileID,
        group: String,
        proxy: String
    ) async -> Bool {
        let operation = Operation.selectProfileProxy(profileID, group)
        guard begin(operation) else { return false }
        let pendingKey = ProfileProxySelectionKey(
            profileID: profileID,
            group: group
        )
        pendingProfileProxySelections[pendingKey] = proxy
        defer {
            pendingProfileProxySelections[pendingKey] = nil
            end(operation)
        }

        guard let (client, snapshot) = await profileProxyOperationContext(
            for: profileID
        ),
        let groupModel = snapshot.proxiesByName[group],
        groupModel.groupBehavior?.supportsSelectionUpdate == true,
        groupModel.all.contains(proxy) else {
            errorMessage = AppLocalization.string(
                "This proxy group cannot select that proxy."
            )
            return false
        }
        do {
            try await client.selectProxy(group: group, proxy: proxy)
            await closeProfileConnectionsAfterRoutingChange(
                using: client,
                profileID: profileID
            )
            let refreshed = await refreshProxyWorkspace(for: profileID)
            return refreshed.snapshot?.proxiesByName[group]?.now == proxy
                || refreshed.snapshot?.proxiesByName[group]?.fixedOverride == proxy
        } catch {
            failProfileProxyWorkspace(
                profileID,
                error: error,
                context: "Profile proxy selection"
            )
            return false
        }
    }

    @discardableResult
    func clearProxyOverride(
        profileID: ProfileID,
        group: String
    ) async -> Bool {
        let operation = Operation.clearProfileProxyOverride(profileID, group)
        guard begin(operation) else { return false }
        defer { end(operation) }
        guard let (client, snapshot) = await profileProxyOperationContext(
            for: profileID
        ),
        snapshot.proxiesByName[group]?
            .groupBehavior?.supportsClearingOverride == true else {
            errorMessage = AppLocalization.string(
                "This proxy group does not have an automatic override to clear."
            )
            return false
        }
        do {
            try await client.clearProxyOverride(group: group)
            await closeProfileConnectionsAfterRoutingChange(
                using: client,
                profileID: profileID
            )
            let refreshed = await refreshProxyWorkspace(for: profileID)
            return refreshed.snapshot != nil
        } catch {
            failProfileProxyWorkspace(
                profileID,
                error: error,
                context: "Restore Profile automatic proxy selection"
            )
            return false
        }
    }

    @discardableResult
    func measureDelay(
        profileID: ProfileID,
        proxy: String,
        group: String? = nil
    ) async -> Int? {
        let operation = Operation.measureProfileProxyDelay(profileID, proxy)
        guard begin(operation) else { return nil }
        defer { end(operation) }
        guard let (client, snapshot) = await profileProxyOperationContext(
            for: profileID
        ),
        let target = delayTarget(
            forProxy: proxy,
            group: group,
            snapshot: snapshot
        ) else {
            return nil
        }
        do {
            let delay = try await client.measureDelay(
                proxy: proxy,
                targetURL: target,
                expectedStatus: expectedDelayStatus(
                    forProxy: proxy,
                    group: group,
                    snapshot: snapshot
                )
            )
            profileProxyMeasuredDelays[profileID, default: [:]][proxy] = delay
            updateProfileProxyWorkspaceDelays(
                profileID: profileID,
                snapshot: snapshot
            )
            if profileID == activeProfileID {
                proxyDelays[proxy] = delay
            }
            return delay
        } catch {
            failProfileProxyWorkspace(
                profileID,
                error: error,
                context: "Profile latency test"
            )
            return nil
        }
    }

    func measureGroupDelays(
        profileID: ProfileID,
        group: String
    ) async {
        let operation = Operation.measureProfileGroupDelay(profileID, group)
        guard begin(operation) else { return }
        defer { end(operation) }
        guard let (client, snapshot) = await profileProxyOperationContext(
            for: profileID
        ),
        let groupModel = snapshot.proxiesByName[group] else {
            return
        }
        let target = delayTarget(for: groupModel) ?? defaultDelayTarget
        let expectedStatus = normalizedExpectedStatus(groupModel.expectedStatus)
        var seen = Set<String>()
        let members = groupModel.all.filter { seen.insert($0).inserted }
        var delays: [String: Int] = [:]
        let maximumConcurrentRequests = 8
        for batchStart in stride(
            from: 0,
            to: members.count,
            by: maximumConcurrentRequests
        ) {
            guard !Task.isCancelled else { return }
            let batchEnd = min(
                batchStart + maximumConcurrentRequests,
                members.count
            )
            let batch = Array(members[batchStart..<batchEnd])
            let batchDelays = await withTaskGroup(
                of: (String, Int?).self,
                returning: [String: Int].self
            ) { taskGroup in
                for proxy in batch {
                    taskGroup.addTask {
                        let delay = try? await client.measureDelay(
                            proxy: proxy,
                            targetURL: target,
                            expectedStatus: expectedStatus
                        )
                        return (proxy, delay)
                    }
                }
                var measured: [String: Int] = [:]
                for await (proxy, delay) in taskGroup {
                    if let delay { measured[proxy] = delay }
                }
                return measured
            }
            delays.merge(batchDelays) { _, new in new }
        }

        profileProxyMeasuredDelays[profileID, default: [:]]
            .merge(delays) { _, new in new }
        updateProfileProxyWorkspaceDelays(
            profileID: profileID,
            snapshot: snapshot
        )
        if profileID == activeProfileID {
            proxyDelays.merge(delays) { _, new in new }
        }
        if delays.isEmpty, !members.isEmpty {
            let error = MihomoAPIError.emptyResponse
            failProfileProxyWorkspace(
                profileID,
                error: error,
                context: "Profile group latency test"
            )
        }
    }

    @discardableResult
    func refreshRules() async -> Bool {
        guard begin(.refreshRules) else { return false }
        defer { end(.refreshRules) }

        guard let apiClient else { return false }
        await loadRules(using: apiClient, generation: controllerGeneration)
        return rulesErrorMessage == nil
    }

    @discardableResult
    func refreshProviders() async -> Bool {
        guard begin(.refreshProviders) else { return false }
        defer { end(.refreshProviders) }

        guard let apiClient else { return false }
        let generation = controllerGeneration
        await loadProviders(using: apiClient, generation: generation)
        guard !Task.isCancelled,
              generation == controllerGeneration,
              isConnected else { return false }
        return providersErrorMessage == nil
    }

    func providerOperationReceipt(
        _ kind: ProviderOperationKind,
        providerName: String
    ) -> ProviderOperationReceipt? {
        providerOperationReceipts[providerReceiptKey(kind, providerName: providerName)]
    }

    func updateProxyProvider(_ name: String) async {
        guard begin(.updateProxyProvider(name)) else { return }
        defer { end(.updateProxyProvider(name)) }

        guard let apiClient else { return }
        let generation = controllerGeneration
        invalidateProxyRefreshes()
        do {
            try await apiClient.updateProxyProvider(named: name)
            guard generation == controllerGeneration, isConnected else { return }
            await loadProviders(using: apiClient, generation: generation)
            await refreshProxyGroups(generation: generation)
            recordProviderOperationReceipt(.updateProxy, providerName: name, outcome: .succeeded)
        } catch {
            guard generation == controllerGeneration else { return }
            providersErrorMessage = error.localizedDescription
            recordProviderOperationReceipt(
                .updateProxy,
                providerName: name,
                outcome: .failed(error.localizedDescription)
            )
            recordOperationFailure(error, context: "Proxy provider update")
        }
    }

    func healthCheckProxyProvider(_ name: String) async {
        guard begin(.healthCheckProxyProvider(name)) else { return }
        defer { end(.healthCheckProxyProvider(name)) }

        guard let apiClient else { return }
        let generation = controllerGeneration
        invalidateProxyRefreshes()
        do {
            try await apiClient.healthCheckProxyProvider(named: name)
            guard generation == controllerGeneration, isConnected else { return }
            await loadProviders(using: apiClient, generation: generation)
            await refreshProxyGroups(generation: generation)
            recordProviderOperationReceipt(.healthCheckProxy, providerName: name, outcome: .succeeded)
        } catch {
            guard generation == controllerGeneration else { return }
            providersErrorMessage = error.localizedDescription
            recordProviderOperationReceipt(
                .healthCheckProxy,
                providerName: name,
                outcome: .failed(error.localizedDescription)
            )
            recordOperationFailure(error, context: "Proxy provider health check")
        }
    }

    func updateRuleProvider(_ name: String) async {
        guard begin(.updateRuleProvider(name)) else { return }
        defer { end(.updateRuleProvider(name)) }

        guard let apiClient else { return }
        let generation = controllerGeneration
        do {
            try await apiClient.updateRuleProvider(named: name)
            guard generation == controllerGeneration, isConnected else { return }
            await loadProviders(using: apiClient, generation: generation)
            await loadRules(using: apiClient, generation: generation)
            recordProviderOperationReceipt(.updateRule, providerName: name, outcome: .succeeded)
        } catch {
            guard generation == controllerGeneration else { return }
            providersErrorMessage = error.localizedDescription
            recordProviderOperationReceipt(
                .updateRule,
                providerName: name,
                outcome: .failed(error.localizedDescription)
            )
            recordOperationFailure(error, context: "Rule provider update")
        }
    }

    private func providerReceiptKey(
        _ kind: ProviderOperationKind,
        providerName: String
    ) -> String {
        "\(kind.rawValue):\(providerName)"
    }

    private func recordProviderOperationReceipt(
        _ kind: ProviderOperationKind,
        providerName: String,
        outcome: ProviderOperationReceipt.Outcome
    ) {
        let receipt = ProviderOperationReceipt(
            kind: kind,
            providerName: providerName,
            completedAt: Date(),
            outcome: outcome
        )
        providerOperationReceipts[providerReceiptKey(kind, providerName: providerName)] = receipt
    }

    @discardableResult
    func closeConnection(_ id: String) async -> Bool {
        guard begin(.closeConnection(id)) else { return false }
        defer { end(.closeConnection(id)) }

        guard let apiClient else { return false }
        let generation = controllerGeneration
        do {
            try await apiClient.closeConnection(id: id)
            guard generation == controllerGeneration else { return false }
            for _ in 0..<20
            where generation == controllerGeneration
                && connections?.connections.contains(where: { $0.id == id }) == true {
                try? await Task.sleep(for: .milliseconds(100))
            }
            return true
        } catch {
            guard generation == controllerGeneration else { return false }
            recordOperationFailure(error, context: "Close connection")
            return false
        }
    }

    @discardableResult
    func closeAllConnections() async -> Bool {
        guard begin(.closeAllConnections) else { return false }
        defer { end(.closeAllConnections) }

        guard let apiClient else { return false }
        let generation = controllerGeneration
        do {
            try await apiClient.closeAllConnections()
            guard generation == controllerGeneration else { return false }
            for _ in 0..<20
            where generation == controllerGeneration
                && connections?.connections.isEmpty == false {
                try? await Task.sleep(for: .milliseconds(100))
            }
            return true
        } catch {
            guard generation == controllerGeneration else { return false }
            recordOperationFailure(error, context: "Close all connections")
            return false
        }
    }

    func setNetworkCaptureEnabled(_ enabled: Bool) async {
        if unifiedConfigurationEnabled {
            let appRoutingEntrance = configurationDocument.entrances.first(where: { $0.kind == .appRouting })
            let currentEnabled = configurationDocument.currentWorkspace?.entranceIDs
                .compactMap { id in configurationDocument.entrances.first(where: { $0.id == id }) }
                .first(where: { $0.kind == .appRouting })?.enabled
                ?? appRoutingEntrance?.enabled
                ?? false
            guard enabled != currentEnabled else { return }
            var candidate = configurationDocument
            if let appRoutingEntrance,
               let workspaceID = candidate.currentWorkspace?.id,
               let workspaceIndex = candidate.workspaces.firstIndex(where: { $0.id == workspaceID }) {
                if !candidate.workspaces[workspaceIndex].entranceIDs.contains(appRoutingEntrance.id) {
                    candidate.workspaces[workspaceIndex].entranceIDs.append(appRoutingEntrance.id)
                    candidate.workspaces[workspaceIndex].revision += 1
                }
                if let index = candidate.entrances.firstIndex(where: { $0.id == appRoutingEntrance.id }) {
                    candidate.entrances[index].enabled = enabled
                }
            } else if let appRoutingEntrance,
                      let index = candidate.entrances.firstIndex(where: { $0.id == appRoutingEntrance.id }) {
                candidate.entrances[index].enabled = enabled
            }
            do {
                let candidateCompiled = try ConfigurationCompiler().compile(
                    document: candidate
                )
                if activeProfileID == nil {
                    await persistNetworkCaptureEnabledWithoutProfile(
                        enabled,
                        rules: candidateCompiled.captureRules,
                        dnsEnabled: candidateCompiled.captureDNSEnabled,
                        configurationDocument: candidate,
                        compiledConfiguration: candidateCompiled
                    )
                } else {
                    try await applyNetworkCaptureRules(
                        candidateCompiled.captureRules,
                        enabled: candidateCompiled.captureEnabled,
                        dnsEnabled: candidateCompiled.captureDNSEnabled,
                        compiledConfiguration: candidateCompiled,
                        configurationDocument: candidate
                    )
                }
            } catch {
                recordOperationFailure(error, context: "Network capture update")
            }
            return
        }
        guard enabled != networkCapturePreferences.enabled else { return }
        if activeProfileID == nil {
            await persistNetworkCaptureEnabledWithoutProfile(enabled)
            return
        }
        do {
            try await applyNetworkCaptureRules(
                networkCapturePreferences.snapshot.rules,
                enabled: enabled,
                // DNS follows the App Routing lifecycle by default. The saved
                // value can only differ through the explicitly advanced opt-out.
                dnsEnabled: networkCapturePreferences.dnsEnabled
            )
        } catch {
            recordOperationFailure(error, context: "Network capture update")
        }
    }

    private func persistNetworkCaptureEnabledWithoutProfile(
        _ enabled: Bool,
        rules: [CaptureRule]? = nil,
        dnsEnabled: Bool? = nil,
        configurationDocument candidateDocument: ConfigurationDocument? = nil,
        compiledConfiguration candidateCompiledConfiguration: CompiledConfiguration? = nil
    ) async {
        guard begin(.changeNetworkCapture) else { return }
        pendingNetworkCaptureEnabled = enabled
        defer {
            pendingNetworkCaptureEnabled = nil
            end(.changeNetworkCapture)
        }
        guard let store = networkCaptureConfigurationStore else {
            recordOperationFailure(
                AppModelError.profileStoreUnavailable,
                context: "Network capture update"
            )
            return
        }

        let previousDocument = configurationDocument
        do {
            if let candidateDocument {
                try await persistConfigurationDocument(candidateDocument)
            }
            networkCapturePreferences = try await store.replaceRules(
                rules ?? networkCapturePreferences.snapshot.rules,
                enabled: enabled,
                dnsEnabled: dnsEnabled ?? networkCapturePreferences.dnsEnabled,
                failOpen: networkCapturePreferences.failOpen
            )
            networkCaptureState = enabled ? .waitingForConnection : .off
            networkCaptureChangeReceipt = NetworkCaptureChangeReceipt(
                completedAt: Date(),
                duration: 0,
                outcome: .savedForNextActivation
            )
            appendSupervisorLog(
                enabled
                    ? "App Routing will start when a profile becomes available."
                    : "Automatic App Routing startup was disabled."
            )
            if let candidateCompiledConfiguration {
                compiledConfiguration = candidateCompiledConfiguration
            }
        } catch {
            if candidateDocument != nil {
                configurationDocument = previousDocument
                configurationDiagnostics = allConfigurationDiagnostics(for: previousDocument)
                try? await configurationStore?.save(previousDocument)
            }
            recordOperationFailure(error, context: "Network capture update")
        }
    }

    func retryNetworkCaptureActivation() async {
        guard networkCapturePreferences.enabled,
              begin(.changeNetworkCapture) else { return }
        defer { end(.changeNetworkCapture) }

        errorMessage = nil
        if isConnected, controllerIsReady {
            await performNetworkCaptureActivation()
        } else {
            _ = await performConnect()
        }
    }

    func applyNetworkCaptureRules(
        _ rules: [CaptureRule],
        enabled: Bool,
        dnsEnabled: Bool? = nil,
        compiledConfiguration candidateCompiledConfiguration: CompiledConfiguration? = nil,
        configurationDocument candidateConfigurationDocument: ConfigurationDocument? = nil
    ) async throws {
        let transactionStartedAt = Date()
        guard begin(.changeNetworkCapture) else {
            throw AppModelError.operationInProgress
        }
        pendingNetworkCaptureEnabled = enabled
        defer {
            pendingNetworkCaptureEnabled = nil
            end(.changeNetworkCapture)
        }
        if unifiedConfigurationEnabled,
           (candidateCompiledConfiguration == nil || candidateConfigurationDocument == nil) {
            throw AppModelError.profileActivationFailed(
                AppLocalization.string("Configuration unavailable")
            )
        }
        guard let store = networkCaptureConfigurationStore,
              let activeProfileID,
              let profileStore,
              runtimeOverrideCoordinator != nil
        else {
            throw AppModelError.profileStoreUnavailable
        }

        let systemProxyWasOn: Bool = {
            if case .on = systemProxyState { return true }
            return false
        }()
        var systemProxyWasDisabled = false
        if enabled, systemProxyEnabled || hasSystemProxySnapshot {
            guard await performDisableSystemProxy() else {
                throw AppModelError.systemProxyRestoreFailed
            }
            systemProxyWasDisabled = systemProxyWasOn
        }

        let previous = networkCapturePreferences
        let previousListener = networkExtensionMihomoListener
        let previousProfileListeners = networkExtensionProfileListeners
        let previousRuntimePlan = profileRuntimePlan
        let previousConfigurationDocument = configurationDocument
        let previousCompiledConfiguration = compiledConfiguration
        let wasConnected = isConnected || isBusy
        let requestedDNSEnabled = dnsEnabled ?? previous.dnsEnabled
        let canAttemptLiveUpdate: Bool = {
            guard previous.enabled,
                  enabled,
                  wasConnected,
                  isConnected,
                  controllerIsReady,
                  requestedDNSEnabled == previous.dnsEnabled,
                  case let .on(activeRevision) = networkCaptureState,
                  activeRevision == previous.snapshot.revision
            else { return false }
            return true
        }()
        let attemptedLiveUpdate = canAttemptLiveUpdate
        do {
            if let candidateCompiledConfiguration {
                compiledConfiguration = candidateCompiledConfiguration
            }
            if enabled {
                try await prepareProfileRoutingSessions(
                    for: rules,
                    captureEnabled: true,
                    startAuxiliary: wasConnected || enabled
                )
            }
            let candidate = try await store.replaceRules(
                rules,
                enabled: enabled,
                // This is the user's persistent choice. Runtime activation is
                // still gated by App Routing being enabled, but rule edits or
                // a temporary disable must never silently erase the choice.
                dnsEnabled: dnsEnabled ?? previous.dnsEnabled,
                failOpen: true
            )
            networkCapturePreferences = candidate
            if unifiedConfigurationEnabled {
                if let candidateConfigurationDocument {
                    try await persistConfigurationDocument(
                        candidateConfigurationDocument
                    )
                }
            }
            if !enabled {
                networkExtensionMihomoListener = nil
            }

            // Editing rules or the DNS preference while App Routing is off is
            // a persistence-only operation. There is no active data plane to
            // recompose, so restarting Mihomo would only interrupt traffic.
            if !previous.enabled, !enabled {
                networkCaptureState = .off
                networkCaptureRollbackFailure = nil
                networkCaptureChangeReceipt = NetworkCaptureChangeReceipt(
                    completedAt: Date(),
                    duration: Date().timeIntervalSince(transactionStartedAt),
                    outcome: .savedForNextActivation
                )
                appendSupervisorLog(
                    "App Routing settings were saved for the next activation; the running core was not restarted."
                )
                if let candidateCompiledConfiguration {
                    compiledConfiguration = candidateCompiledConfiguration
                }
                return
            }

            // Matcher, priority, and action edits are committed directly to
            // the running data plane. Missing private routes are appended to
            // the affected Mihomo session through its controller; removed
            // routes remain as an idle listener superset until a cold start.
            // Existing relays retain the plan they started with, while new
            // flows use the new revision.
            if canAttemptLiveUpdate,
               candidate.dnsEnabled == previous.dnsEnabled,
               case let .on(activeRevision) = networkCaptureState,
               activeRevision == previous.snapshot.revision,
               let listener = networkExtensionMihomoListener {
                try await hotReloadActiveProfileRoutingConfigurationIfNeeded(
                    profileID: activeProfileID
                )
                try await localPortProbe.waitUntilListening(
                    ports: Set(
                        try activeNetworkExtensionRouteProxyEndpoints().map {
                            Int($0.port)
                        }
                    )
                )
                let configuration = try NetworkExtensionRuntimeConfiguration(
                    preferences: candidate,
                    mihomoListener: listener,
                    routeProxyEndpoints: try activeNetworkExtensionRouteProxyEndpoints()
                )
                let updateOutcome = try await networkExtensionControl
                    .updateRuntimeConfiguration(configuration)
                guard updateOutcome == .running else {
                    throw AppModelError.profileActivationFailed(
                        AppLocalization.string(
                            "The live App Routing update did not reach a verified running state."
                        )
                    )
                }
                networkCaptureState = .on(revision: configuration.revision)
                appRoutingProviderStatusFailureCount = 0
                appRoutingProviderLastVerifiedAt = Date()
                dnsProxyRuntimeFailureCount = 0
                dnsProxyAutomaticallyDisabled = false
                markStreamHealthy(.appRouting)
                startDNSProxyRuntimeMonitor()
                launchAppRoutingActivityMonitor(forceRestart: true)
                networkCaptureRollbackFailure = nil
                networkCaptureChangeReceipt = NetworkCaptureChangeReceipt(
                    completedAt: Date(),
                    duration: Date().timeIntervalSince(transactionStartedAt),
                    outcome: .rulesUpdatedLive(dnsEnabled: candidate.dnsEnabled)
                )
                appendSupervisorLog(
                    "App Routing rules were updated live; Mihomo and existing relays stayed connected."
                )
                if let candidateCompiledConfiguration {
                    compiledConfiguration = candidateCompiledConfiguration
                }
                return
            }

            if wasConnected {
                guard await performDisconnect() else {
                    throw AppModelError.networkCaptureDisableFailed
                }
            }
            if !enabled {
                try await prepareProfileRoutingSessions(
                    for: [],
                    captureEnabled: false,
                    startAuxiliary: wasConnected
                )
            }

            let activation = try await activateStoredProfile(
                activeProfileID,
                validator: try makeProfileValidator()
            )
            self.activeProfileID = activation.profileID
            activeConfigURL = activation.configurationURL
            profiles = try await profileStore.profiles()

            if wasConnected || enabled {
                guard await performConnect() else {
                    throw AppModelError.profileActivationFailed(
                        errorMessage ?? AppLocalization.string(
                            "The core could not restart with network capture settings."
                        )
                    )
                }
            } else {
                networkCaptureState = .off
            }
            if enabled {
                switch networkCaptureState {
                case let .on(revision) where revision == candidate.snapshot.revision:
                    appendSupervisorLog("Per-application network capture is enabled.")
                case .requiresReboot:
                    appendSupervisorLog(
                        "App Routing is configured and will finish enabling after a Mac restart."
                    )
                    networkCaptureRollbackFailure = nil
                    networkCaptureChangeReceipt = NetworkCaptureChangeReceipt(
                        completedAt: Date(),
                        duration: Date().timeIntervalSince(transactionStartedAt),
                        outcome: .requiresReboot(dnsEnabled: candidate.dnsEnabled)
                    )
                    if let candidateCompiledConfiguration {
                        compiledConfiguration = candidateCompiledConfiguration
                    }
                    return
                case let .failed(message):
                    throw AppModelError.profileActivationFailed(
                        AppLocalization.format(
                            "App Routing activation failed verification: %@",
                            message
                        )
                    )
                case .on, .waitingForConnection, .enabling, .awaitingUserApproval,
                     .off, .disabling:
                    throw AppModelError.profileActivationFailed(
                        AppLocalization.string(
                            "App Routing did not reach a verified running state."
                        )
                    )
                }
            } else {
                appendSupervisorLog("Per-application network capture is disabled.")
            }
            networkCaptureRollbackFailure = nil
            networkCaptureChangeReceipt = NetworkCaptureChangeReceipt(
                completedAt: Date(),
                duration: Date().timeIntervalSince(transactionStartedAt),
                outcome: .appliedAndVerified(
                    enabled: enabled,
                    dnsEnabled: candidate.dnsEnabled,
                    systemProxyWasDisabled: systemProxyWasDisabled
                )
            )
            if let candidateCompiledConfiguration {
                compiledConfiguration = candidateCompiledConfiguration
            }
        } catch {
            let primaryError = error
            var rollbackFailures: [String] = []

            configurationDocument = previousConfigurationDocument
            configurationDiagnostics = allConfigurationDiagnostics(for: previousConfigurationDocument)
            compiledConfiguration = previousCompiledConfiguration
            do {
                try await configurationStore?.save(previousConfigurationDocument)
            } catch {
                rollbackFailures.append(
                    AppLocalization.format(
                        "MClash Workspace state rollback failed: %@",
                        error.localizedDescription
                    )
                )
            }

            do {
                networkExtensionMihomoListener = previous.enabled ? previousListener : nil
                networkExtensionProfileListeners = previous.enabled
                    ? previousProfileListeners
                    : [:]
                profileRuntimePlan = previousRuntimePlan
                try? await profileRuntimePlanStore?.save(previousRuntimePlan)
                networkCapturePreferences = try await store.replaceRules(
                    previous.snapshot.rules,
                    enabled: previous.enabled,
                    dnsEnabled: previous.dnsEnabled,
                    failOpen: previous.failOpen
                )
            } catch {
                rollbackFailures.append(
                    AppLocalization.format(
                        "saved App Routing settings: %@",
                        error.localizedDescription
                    )
                )
            }

            if attemptedLiveUpdate {
                guard rollbackFailures.isEmpty else {
                    let transactionError = NetworkCaptureTransactionFailure(
                        updateReason: primaryError.localizedDescription,
                        rollbackReason: AppLocalization.format(
                            "The previous durable rules could not be restored without stopping Mihomo: %@",
                            rollbackFailures.joined(separator: "; ")
                        )
                    )
                    networkCaptureRollbackFailure = transactionError.localizedDescription
                    networkCaptureChangeReceipt = NetworkCaptureChangeReceipt(
                        completedAt: Date(),
                        duration: Date().timeIntervalSince(transactionStartedAt),
                        outcome: .rollbackFailed(transactionError.localizedDescription)
                    )
                    appendSupervisorLog(
                        "App Routing durable rollback failed; the running cores were intentionally left online. \(transactionError.localizedDescription)"
                    )
                    throw transactionError
                }
                do {
                    try await prepareProfileRoutingSessions(
                        for: previous.enabled ? previous.snapshot.rules : [],
                        captureEnabled: previous.enabled,
                        startAuxiliary: wasConnected
                    )
                    try await hotReloadActiveProfileRoutingConfigurationIfNeeded(
                        profileID: activeProfileID
                    )
                    guard let listener = networkExtensionMihomoListener else {
                        throw AppModelError.profileActivationFailed(
                            AppLocalization.string(
                                "The previous private App Routing listener could not be restored."
                            )
                        )
                    }
                    let rollbackConfiguration = try NetworkExtensionRuntimeConfiguration(
                        preferences: networkCapturePreferences,
                        mihomoListener: listener,
                        routeProxyEndpoints: try activeNetworkExtensionRouteProxyEndpoints()
                    )
                    let rollbackOutcome = try await networkExtensionControl
                        .updateRuntimeConfiguration(rollbackConfiguration)
                    guard rollbackOutcome == .running else {
                        throw AppModelError.profileActivationFailed(
                            AppLocalization.string(
                                "The previous App Routing revision did not return to a running state."
                            )
                        )
                    }
                    networkCaptureState = .on(
                        revision: rollbackConfiguration.revision
                    )
                    networkCaptureRollbackFailure = nil
                    networkCaptureChangeReceipt = NetworkCaptureChangeReceipt(
                        completedAt: Date(),
                        duration: Date().timeIntervalSince(transactionStartedAt),
                        outcome: .rejectedAndRolledBack(
                            primaryError.localizedDescription
                        )
                    )
                    appendSupervisorLog(
                        "The App Routing live update was rejected; the previous rules were restored without restarting Mihomo."
                    )
                } catch {
                    let transactionError = NetworkCaptureTransactionFailure(
                        updateReason: primaryError.localizedDescription,
                        rollbackReason: AppLocalization.format(
                            "Live rollback failed without stopping Mihomo: %@",
                            error.localizedDescription
                        )
                    )
                    networkCaptureRollbackFailure = transactionError.localizedDescription
                    networkCaptureChangeReceipt = NetworkCaptureChangeReceipt(
                        completedAt: Date(),
                        duration: Date().timeIntervalSince(transactionStartedAt),
                        outcome: .rollbackFailed(transactionError.localizedDescription)
                    )
                    appendSupervisorLog(
                        "App Routing live rollback failed; the running cores were intentionally left online. \(transactionError.localizedDescription)"
                    )
                    throw transactionError
                }
                throw primaryError
            }

            if isConnected || isBusy {
                let disconnected = await performDisconnect()
                if !disconnected {
                    rollbackFailures.append(
                        AppLocalization.string(
                            "running core: could not stop it before restoration"
                        )
                    )
                }
            }

            do {
                try await prepareProfileRoutingSessions(
                    for: previous.enabled ? previous.snapshot.rules : [],
                    captureEnabled: previous.enabled,
                    startAuxiliary: wasConnected
                )
                let rollback = try await activateStoredProfile(
                    activeProfileID,
                    validator: try makeProfileValidator()
                )
                self.activeProfileID = rollback.profileID
                activeConfigURL = rollback.configurationURL
                profiles = try await profileStore.profiles()
            } catch {
                rollbackFailures.append(
                    AppLocalization.format(
                        "active profile: %@",
                        error.localizedDescription
                    )
                )
            }

            if wasConnected {
                let reconnected = await performConnect()
                if !reconnected {
                    rollbackFailures.append(
                        AppLocalization.format(
                            "mihomo core: %@",
                            errorMessage ?? AppLocalization.string(
                                "the previous session could not be restarted"
                            )
                        )
                    )
                }
            }

            if systemProxyWasOn {
                if networkCapturePreferences.enabled {
                    rollbackFailures.append(
                        AppLocalization.string(
                            "System Proxy: App Routing remained enabled, so restoring the mutually exclusive proxy would be unsafe"
                        )
                    )
                } else {
                    await performEnableSystemProxy()
                    if case .on = systemProxyState {
                        appendSupervisorLog(
                            "Network capture rollback restored the previously enabled macOS System Proxy."
                        )
                    } else {
                        rollbackFailures.append(
                            AppLocalization.format(
                                "System Proxy: %@",
                                errorMessage ?? AppLocalization.string(
                                    "the previous macOS proxy could not be re-enabled and verified"
                                )
                            )
                        )
                    }
                }
            }

            let elapsed = Date().timeIntervalSince(transactionStartedAt)
            if rollbackFailures.isEmpty {
                networkCaptureRollbackFailure = nil
                networkCaptureChangeReceipt = NetworkCaptureChangeReceipt(
                    completedAt: Date(),
                    duration: elapsed,
                    outcome: .rejectedAndRolledBack(primaryError.localizedDescription)
                )
                appendSupervisorLog(
                    "App Routing change was rejected and all previous network state was restored: \(primaryError.localizedDescription)"
                )
                throw primaryError
            } else {
                let rollbackDetail = rollbackFailures.joined(separator: "; ")
                let transactionError = NetworkCaptureTransactionFailure(
                    updateReason: primaryError.localizedDescription,
                    rollbackReason: rollbackDetail
                )
                networkCaptureRollbackFailure = transactionError.localizedDescription
                networkCaptureChangeReceipt = NetworkCaptureChangeReceipt(
                    completedAt: Date(),
                    duration: elapsed,
                    outcome: .rollbackFailed(transactionError.localizedDescription)
                )
                appendSupervisorLog(
                    "Network capture rollback failed: \(transactionError.localizedDescription)"
                )
                throw transactionError
            }
        }
    }

    func setDNSCaptureEnabled(_ enabled: Bool) async {
        guard enabled != networkCapturePreferences.dnsEnabled
                || dnsProxyAutomaticallyDisabled else { return }
        do {
            if unifiedConfigurationEnabled {
                var candidate = configurationDocument
                guard let workspace = candidate.currentWorkspace,
                      let index = candidate.dnsPolicies.firstIndex(where: {
                          $0.id == workspace.dnsPolicyID
                      }) else {
                    throw AppModelError.profileStoreUnavailable
                }
                candidate.dnsPolicies[index].takeoverEnabled = enabled
                let compiled = try ConfigurationCompiler().compile(
                    document: candidate
                )
                if activeProfileID == nil {
                    await persistNetworkCaptureEnabledWithoutProfile(
                        compiled.captureEnabled,
                        rules: compiled.captureRules,
                        dnsEnabled: compiled.captureDNSEnabled,
                        configurationDocument: candidate,
                        compiledConfiguration: compiled
                    )
                } else {
                    try await applyNetworkCaptureRules(
                        compiled.captureRules,
                        enabled: compiled.captureEnabled,
                        dnsEnabled: compiled.captureDNSEnabled,
                        compiledConfiguration: compiled,
                        configurationDocument: candidate
                    )
                }
                return
            }
            try await applyNetworkCaptureRules(
                networkCapturePreferences.snapshot.rules,
                enabled: networkCapturePreferences.enabled,
                dnsEnabled: enabled
            )
        } catch {
            recordOperationFailure(error, context: "DNS routing update")
        }
    }

    func retryDNSCaptureActivation() async {
        guard networkCapturePreferences.enabled,
              networkCapturePreferences.dnsEnabled else { return }
        dnsProxyAutomaticallyDisabled = false
        dnsProxyRuntimeFailureCount = 0
        do {
            if unifiedConfigurationEnabled {
                guard let compiledConfiguration else {
                    throw AppModelError.profileStoreUnavailable
                }
                try await applyNetworkCaptureRules(
                    compiledConfiguration.captureRules,
                    enabled: compiledConfiguration.captureEnabled,
                    dnsEnabled: compiledConfiguration.captureDNSEnabled,
                    compiledConfiguration: compiledConfiguration,
                    configurationDocument: configurationDocument
                )
                return
            }
            try await applyNetworkCaptureRules(
                networkCapturePreferences.snapshot.rules,
                enabled: true,
                dnsEnabled: true
            )
        } catch {
            recordOperationFailure(error, context: "DNS routing retry")
        }
    }

    private func performNetworkCaptureActivation() async {
        guard !shutdownInProgress else { return }
        guard networkCapturePreferences.enabled else {
            networkCaptureState = .off
            return
        }
        if case let .on(revision) = networkCaptureState,
           revision == networkCapturePreferences.snapshot.revision {
            return
        }
        if let networkCaptureActivationOperation {
            await networkCaptureActivationOperation.task.value
            return
        }
        if let networkCaptureDeactivationOperation {
            _ = await networkCaptureDeactivationOperation.task.value
        }

        let id = UUID()
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.runNetworkCaptureActivation()
        }
        networkCaptureActivationOperation = (id, task)
        await task.value
        if networkCaptureActivationOperation?.id == id {
            networkCaptureActivationOperation = nil
        }
    }

    private func runNetworkCaptureActivation() async {
        guard !shutdownInProgress else { return }
        guard networkCapturePreferences.enabled else {
            networkCaptureState = .off
            return
        }
        guard let listener = activeNetworkExtensionMihomoListener else {
            reportNetworkCaptureFailure(
                AppLocalization.string("The private mihomo listener is unavailable.")
            )
            return
        }
        networkCaptureState = .enabling
        dnsProxyRuntimeStatus = nil
        dnsProxyRuntimeError = nil
        dnsProxyAutomaticallyDisabled = false
        do {
            let routeProxyEndpoints = try activeNetworkExtensionRouteProxyEndpoints()
            try await localPortProbe.waitUntilListening(
                ports: Set(routeProxyEndpoints.map { Int($0.port) })
            )
            let configuration = try NetworkExtensionRuntimeConfiguration(
                preferences: networkCapturePreferences,
                mihomoListener: listener,
                routeProxyEndpoints: routeProxyEndpoints
            )
            guard !shutdownInProgress else { throw CancellationError() }
            let outcome = try await networkExtensionControl.enable(
                configuration,
                progress: { [weak self] progress in
                    Task { @MainActor in
                        guard let self,
                              progress == .awaitingSystemExtensionApproval,
                              self.networkCapturePreferences.enabled,
                              self.networkCaptureState == .enabling else { return }
                        self.networkCaptureState = .awaitingUserApproval
                    }
                }
            )
            guard !shutdownInProgress else {
                try? await networkExtensionControl.disable()
                networkCaptureState = .off
                return
            }
            switch outcome {
            case .running:
                networkCaptureState = .on(revision: configuration.revision)
                dnsProxyAutomaticallyDisabled = false
                dnsProxyRuntimeFailureCount = 0
                startAppRoutingActivityMonitor()
                appendSupervisorLog(
                    "Network Extension is routing selected flows through mihomo."
                )
            case .requiresReboot:
                networkCaptureState = .requiresReboot
                appendSupervisorLog(
                    "Network Extension installation requires a Mac restart."
                )
            }
        } catch {
            guard !shutdownInProgress else {
                networkCaptureState = .off
                return
            }
            let message = error.localizedDescription
            reportNetworkCaptureFailure(message)
        }
    }

    private func reportNetworkCaptureFailure(_ message: String) {
        networkCaptureState = .failed(message)
        dnsProxyRuntimeStatus = nil
        if networkCapturePreferences.dnsEnabled {
            dnsProxyRuntimeError = message
            dnsProxyAutomaticallyDisabled = true
        }
        errorMessage = AppLocalization.format(
            "App Routing couldn’t start: %@",
            message
        )
        appendSupervisorLog("Network Extension activation failed: \(message)")
    }

    @discardableResult
    private func performNetworkCaptureDeactivation() async -> Bool {
        if let networkCaptureActivationOperation {
            await networkCaptureActivationOperation.task.value
        }
        if let networkCaptureDeactivationOperation {
            return await networkCaptureDeactivationOperation.task.value
        }

        let id = UUID()
        let task = Task { @MainActor [weak self] in
            guard let self else { return true }
            return await self.runNetworkCaptureDeactivation()
        }
        networkCaptureDeactivationOperation = (id, task)
        let result = await task.value
        if networkCaptureDeactivationOperation?.id == id {
            networkCaptureDeactivationOperation = nil
        }
        return result
    }

    @discardableResult
    private func runNetworkCaptureDeactivation() async -> Bool {
        networkCaptureState = .disabling
        stopAppRoutingActivityMonitor()
        do {
            try await networkExtensionControl.disable()
            // An explicit App Routing shutdown is also the end of the coupled
            // DNS lifecycle. Clear a prior runtime failure so the next enable
            // performs a fresh DNS activation instead of displaying stale state.
            dnsProxyAutomaticallyDisabled = false
            dnsProxyRuntimeError = nil
            networkCaptureState = .off
            if !networkEnvironmentRecoveryPolicy.isSleeping,
               networkEnvironmentRecoveryTask == nil,
               networkEnvironmentDebounceTask == nil {
                appRoutingMonitorsPausedForSleep = false
            }
            return true
        } catch {
            let message = error.localizedDescription
            networkCaptureState = .failed(message)
            errorMessage = message
            appendSupervisorLog("Network Extension shutdown failed: \(message)")
            if !networkEnvironmentRecoveryPolicy.isSleeping,
               networkEnvironmentRecoveryTask == nil,
               networkEnvironmentDebounceTask == nil {
                appRoutingMonitorsPausedForSleep = false
            }
            return false
        }
    }

    func toggleSystemProxy() async {
        guard begin(.changeSystemProxy) else { return }
        pendingSystemProxyEnabled = !systemProxyEnabled
        defer {
            pendingSystemProxyEnabled = nil
            end(.changeSystemProxy)
        }

        if systemProxyEnabled {
            shouldReenableSystemProxyAfterCrash = false
            await performDisableSystemProxy()
        } else {
            await performEnableSystemProxy()
        }
    }

    func setSystemProxyEnabled(_ enabled: Bool) async {
        guard enabled != systemProxyEnabled else { return }
        guard begin(.changeSystemProxy) else { return }
        pendingSystemProxyEnabled = enabled
        defer {
            pendingSystemProxyEnabled = nil
            end(.changeSystemProxy)
        }

        if enabled {
            await performEnableSystemProxy()
        } else {
            shouldReenableSystemProxyAfterCrash = false
            await performDisableSystemProxy()
        }
    }

    func enableSystemProxy() async {
        guard begin(.changeSystemProxy) else { return }
        pendingSystemProxyEnabled = true
        defer {
            pendingSystemProxyEnabled = nil
            end(.changeSystemProxy)
        }
        await performEnableSystemProxy()
    }

    private func performEnableSystemProxy() async {
        guard !shutdownInProgress else { return }
        if let operation = systemProxyEnableOperation {
            await operation.task.value
            return
        }

        let id = UUID()
        let task = Task { [weak self] in
            guard let self else { return }
            await self.performSystemProxyActivation()
        }
        systemProxyEnableOperation = (id, task)
        await task.value
        if systemProxyEnableOperation?.id == id {
            systemProxyEnableOperation = nil
        }
    }

    private func performSystemProxyActivation() async {
        guard !shutdownInProgress else { return }
        if case .on = systemProxyState { return }
        if case .enabling = systemProxyState { return }
        guard !networkCapturePreferences.enabled else {
            errorMessage = AppLocalization.string(
                "Turn off per-application network capture before enabling the macOS system proxy."
            )
            return
        }
        guard isConnected, runtimeConfig != nil else {
            errorMessage = AppLocalization.string(
                "Connect the core before enabling the macOS system proxy."
            )
            return
        }
        guard let profileLayout else {
            errorMessage = AppLocalization.string(
                "The application state directory is unavailable."
            )
            return
        }

        let generation = controllerGeneration
        systemProxyGuardFailure = nil
        systemProxyGuardLastVerifiedAt = nil
        systemProxyGuardLastRepairedAt = nil
        systemProxyGuardRepairCount = 0
        systemProxyState = .enabling
        do {
            guard let httpPort = localHTTPProxyPort, let socksPort = localSOCKSProxyPort else {
                throw AppModelError.localProxyPortsUnavailable
            }
            let endpoints = try LocalSystemProxyEndpoints(
                http: SystemProxyEndpoint(port: httpPort),
                https: SystemProxyEndpoint(port: httpPort),
                socks: SystemProxyEndpoint(port: socksPort)
            )
            let snapshotURL = systemProxySnapshotURL(layout: profileLayout)
            try await systemProxyManager.activate(
                endpoints: endpoints,
                bypassDomains: systemProxyPreferences.effectiveBypassDomains,
                savingSnapshotTo: snapshotURL
            )
            guard try await systemProxyManager.configurationMatches(
                endpoints: endpoints,
                bypassDomains: systemProxyPreferences.effectiveBypassDomains
            ) else {
                throw AppModelError.systemProxyGuardVerificationFailed
            }
            guard !shutdownInProgress,
                  generation == controllerGeneration,
                  isConnected else {
                _ = await performDisableSystemProxy()
                return
            }
            systemProxyGuardLastVerifiedAt = Date()
            systemProxyState = .on
            systemProxyObservedEnabled = true
            systemProxyObservedMatchesMClash = true
            systemProxyObservedAt = Date()
            startSystemProxyGuard(endpoints: endpoints)
            appendSupervisorLog(
                "System proxy enabled: HTTP 127.0.0.1:\(httpPort), SOCKS5 127.0.0.1:\(socksPort)."
            )
        } catch {
            let message = error.localizedDescription
            if let proxyError = error as? SystemProxyError,
               proxyError.isAuthorizationFailure {
                autoEnableSystemProxy = false
            }
            if hasSystemProxySnapshot {
                systemProxyState = .failed(message)
                _ = await performDisableSystemProxy()
            } else {
                systemProxyState = .off
                systemProxyObservedEnabled = false
                systemProxyObservedMatchesMClash = false
                systemProxyObservedAt = Date()
            }
            errorMessage = message
            appendSupervisorLog("System proxy could not be enabled: \(message)")
        }
    }

    func disableSystemProxy() async {
        guard begin(.changeSystemProxy) else { return }
        pendingSystemProxyEnabled = false
        defer {
            pendingSystemProxyEnabled = nil
            end(.changeSystemProxy)
        }
        shouldReenableSystemProxyAfterCrash = false
        await performDisableSystemProxy()
    }

    @discardableResult
    private func performDisableSystemProxy() async -> Bool {
        systemProxyGuardTask?.cancel()
        systemProxyGuardTask = nil
        if let operation = systemProxyRestoreOperation {
            return await operation.task.value
        }

        let id = UUID()
        let task = Task { [weak self] in
            guard let self else { return false }
            return await self.performSystemProxyRestore()
        }
        systemProxyRestoreOperation = (id, task)
        let result = await task.value
        if systemProxyRestoreOperation?.id == id {
            systemProxyRestoreOperation = nil
        }
        return result
    }

    func applySystemProxyPreferences(
        _ preferences: SystemProxyPreferences,
        endpoints explicitEndpoints: LocalSystemProxyEndpoints? = nil
    ) async throws {
        guard begin(.changeSystemProxySettings) else {
            throw AppModelError.operationInProgress
        }
        defer { end(.changeSystemProxySettings) }
        guard let systemProxyPreferencesStore else {
            throw AppModelError.profileStoreUnavailable
        }

        let updatedPreferences = try preferences.validated()
        let previousPreferences = systemProxyPreferences

        guard systemProxyEnabled else {
            try await systemProxyPreferencesStore.save(updatedPreferences)
            systemProxyPreferences = updatedPreferences
            systemProxySettingsReceipt = SystemProxySettingsReceipt(
                completedAt: Date(),
                outcome: .savedForNextConnection
            )
            systemProxyGuardTask?.cancel()
            systemProxyGuardTask = nil
            return
        }
        guard let endpoints = explicitEndpoints ?? currentSystemProxyEndpoints() else {
            throw AppModelError.localProxyPortsUnavailable
        }

        systemProxyGuardTask?.cancel()
        systemProxyGuardTask = nil
        do {
            guard !shutdownInProgress else { throw CancellationError() }
            try await systemProxyManager.apply(
                endpoints: endpoints,
                bypassDomains: updatedPreferences.effectiveBypassDomains
            )
            guard !shutdownInProgress else { throw CancellationError() }
            guard try await systemProxyManager.configurationMatches(
                endpoints: endpoints,
                bypassDomains: updatedPreferences.effectiveBypassDomains
            ) else {
                throw AppModelError.systemProxyGuardVerificationFailed
            }
            guard !shutdownInProgress else { throw CancellationError() }
            try await systemProxyPreferencesStore.save(updatedPreferences)
            systemProxyPreferences = updatedPreferences
            systemProxyGuardFailure = nil
            systemProxyGuardLastVerifiedAt = Date()
            systemProxyState = .on
            systemProxyObservedEnabled = true
            systemProxyObservedMatchesMClash = true
            systemProxyObservedAt = Date()
            systemProxySettingsReceipt = SystemProxySettingsReceipt(
                completedAt: Date(),
                outcome: .appliedAndVerified
            )
            startSystemProxyGuard(endpoints: endpoints)
        } catch {
            let updateError = error
            guard !shutdownInProgress else {
                systemProxyState = hasSystemProxySnapshot
                    ? .failed(
                        AppLocalization.string(
                            "System proxy settings update was interrupted by shutdown."
                        )
                    )
                    : .off
                throw CancellationError()
            }
            var rollbackError: (any Error)?
            do {
                try await systemProxyManager.apply(
                    endpoints: endpoints,
                    bypassDomains: previousPreferences.effectiveBypassDomains
                )
                guard !shutdownInProgress else { throw CancellationError() }
                guard try await systemProxyManager.configurationMatches(
                    endpoints: endpoints,
                    bypassDomains: previousPreferences.effectiveBypassDomains
                ) else {
                    throw AppModelError.systemProxyGuardVerificationFailed
                }
                systemProxyPreferences = previousPreferences
                systemProxyGuardFailure = nil
                systemProxyGuardLastVerifiedAt = Date()
                systemProxyState = .on
                systemProxyObservedEnabled = true
                systemProxyObservedMatchesMClash = true
                systemProxyObservedAt = Date()
                systemProxySettingsReceipt = SystemProxySettingsReceipt(
                    completedAt: Date(),
                    outcome: .rejectedAndRolledBack(updateError.localizedDescription)
                )
                startSystemProxyGuard(endpoints: endpoints)
            } catch {
                rollbackError = error
            }

            if let rollbackError {
                let failure = SystemProxyPreferenceRollbackFailure(
                    updateReason: updateError.localizedDescription,
                    rollbackReason: rollbackError.localizedDescription
                )
                let now = Date()
                systemProxyGuardFailure = SystemProxyGuardFailure(
                    consecutiveFailures: Self.systemProxyGuardFailureThreshold,
                    firstFailureAt: now,
                    lastFailureAt: now,
                    reason: failure.localizedDescription
                )
                systemProxyState = .failed(failure.localizedDescription)
                systemProxySettingsReceipt = SystemProxySettingsReceipt(
                    completedAt: Date(),
                    outcome: .rollbackFailed(failure.localizedDescription)
                )
                throw failure
            }
            throw updateError
        }
    }

    @discardableResult
    func setSystemProxyGuardPaused(_ paused: Bool) async -> Bool {
        var preferences = systemProxyPreferences
        guard preferences.guardEnabled == paused else { return true }
        preferences.guardEnabled = !paused
        do {
            try await applySystemProxyPreferences(preferences)
            appendSupervisorLog(
                paused
                    ? "System proxy guard paused; current macOS proxy settings were left in place."
                    : "System proxy guard resumed and verified."
            )
            return true
        } catch {
            recordOperationFailure(
                error,
                context: paused ? "Pause system proxy guard" : "Resume system proxy guard"
            )
            return false
        }
    }

    func verifySystemProxyGuardNow() async throws {
        guard systemProxyEnabled else {
            throw AppModelError.profileActivationFailed(
                AppLocalization.string("The macOS System Proxy is not enabled.")
            )
        }
        guard let endpoints = currentSystemProxyEndpoints() else {
            throw AppModelError.localProxyPortsUnavailable
        }
        await performSystemProxyGuardCheck(
            endpoints: endpoints,
            bypassDomains: systemProxyPreferences.effectiveBypassDomains
        )
        if let failure = systemProxyGuardFailure {
            throw AppModelError.profileActivationFailed(failure.reason)
        }
    }

    private func currentSystemProxyEndpoints() -> LocalSystemProxyEndpoints? {
        guard let httpPort = localHTTPProxyPort,
              let socksPort = localSOCKSProxyPort else { return nil }
        return try? LocalSystemProxyEndpoints(
            http: SystemProxyEndpoint(port: httpPort),
            https: SystemProxyEndpoint(port: httpPort),
            socks: SystemProxyEndpoint(port: socksPort)
        )
    }

    private func startSystemProxyGuard(endpoints: LocalSystemProxyEndpoints) {
        systemProxyGuardTask?.cancel()
        guard systemProxyPreferences.guardEnabled else {
            systemProxyGuardTask = nil
            if systemProxyGuardFailure != nil {
                systemProxyGuardFailure = nil
                systemProxyState = .on
                systemProxyObservedEnabled = true
                systemProxyObservedMatchesMClash = true
                systemProxyObservedAt = Date()
            }
            return
        }
        let interval = systemProxyPreferences.guardIntervalSeconds
        let bypassDomains = systemProxyPreferences.effectiveBypassDomains
        systemProxyGuardTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(
                        for: .seconds(interval),
                        tolerance: .milliseconds(500),
                        clock: .suspending
                    )
                } catch {
                    return
                }
                guard let self,
                      self.isConnected,
                      self.systemProxyGuardCanVerify else { return }
                await self.performSystemProxyGuardCheck(
                    endpoints: endpoints,
                    bypassDomains: bypassDomains
                )
            }
        }
    }

    private var systemProxyGuardCanVerify: Bool {
        switch systemProxyState {
        case .on:
            true
        case .failed where systemProxyGuardFailure != nil:
            true
        case .off, .enabling, .disabling, .failed:
            false
        }
    }

    /// One complete verify-and-repair cycle. Kept internal so safety tests can
    /// prove the state transitions without waiting for the periodic timer.
    func performSystemProxyGuardCheck(
        endpoints: LocalSystemProxyEndpoints,
        bypassDomains: [String],
        recoveryGeneration: UInt64? = nil
    ) async {
        func canContinue() -> Bool {
            guard !shutdownInProgress, systemProxyGuardCanVerify else { return false }
            guard let recoveryGeneration else { return true }
            return networkEnvironmentRecoveryCanContinue(generation: recoveryGeneration)
        }

        guard canContinue() else { return }
        do {
            let matches = try await systemProxyManager.configurationMatches(
                endpoints: endpoints,
                bypassDomains: bypassDomains
            )
            guard canContinue() else { return }
            if !matches {
                let detectedAt = Date()
                guard canContinue() else { return }
                try await systemProxyManager.apply(
                    endpoints: endpoints,
                    bypassDomains: bypassDomains
                )
                guard canContinue() else { return }
                let repairedConfigurationMatches = try await systemProxyManager.configurationMatches(
                    endpoints: endpoints,
                    bypassDomains: bypassDomains
                )
                guard canContinue() else { return }
                guard repairedConfigurationMatches else {
                    throw AppModelError.systemProxyGuardVerificationFailed
                }
                appendSupervisorLog(
                    "System proxy guard restored and verified externally changed settings."
                )
                systemProxyGuardLastRepairedAt = detectedAt
                if systemProxyGuardRepairCount < Int.max {
                    systemProxyGuardRepairCount += 1
                }
            }

            systemProxyGuardLastVerifiedAt = Date()
            if systemProxyGuardFailure != nil {
                appendSupervisorLog("System proxy guard verification recovered.")
                systemProxyGuardFailure = nil
                systemProxyState = .on
                systemProxyObservedEnabled = true
                systemProxyObservedMatchesMClash = true
                systemProxyObservedAt = Date()
            }
        } catch {
            guard canContinue() else { return }
            recordSystemProxyGuardFailure(error)
        }
    }

    private func recordSystemProxyGuardFailure(_ error: any Error) {
        let now = Date()
        let previous = systemProxyGuardFailure
        let count = (previous?.consecutiveFailures ?? 0) + 1
        let reason = error.localizedDescription
        systemProxyGuardFailure = SystemProxyGuardFailure(
            consecutiveFailures: count,
            firstFailureAt: previous?.firstFailureAt ?? now,
            lastFailureAt: now,
            reason: reason
        )

        if count == 1 {
            appendSupervisorLog("System proxy guard could not verify settings: \(reason)")
        }
        if count >= Self.systemProxyGuardFailureThreshold {
            let message = AppLocalization.format(
                "MClash could not verify or restore the macOS system proxy after %@ consecutive attempts. Last error: %@",
                String(count),
                reason
            )
            systemProxyState = .failed(message)
            if count == Self.systemProxyGuardFailureThreshold {
                appendSupervisorLog(message)
            }
        }
    }

    @discardableResult
    private func performSystemProxyRestore() async -> Bool {
        guard let profileLayout else {
            let message = AppLocalization.string(
                "The application state directory is unavailable."
            )
            systemProxyState = .failed(message)
            errorMessage = message
            return false
        }
        let snapshotURL = systemProxySnapshotURL(layout: profileLayout)

        let wasRecovering = systemProxyRecoveryRequired
        systemProxyGuardFailure = nil
        systemProxyGuardLastVerifiedAt = nil
        systemProxyGuardLastRepairedAt = nil
        systemProxyGuardRepairCount = 0
        systemProxyState = .disabling
        do {
            if FileManager.default.fileExists(atPath: snapshotURL.path) {
                try await systemProxyManager.restoreSnapshotAndRemove(from: snapshotURL)
            }
            systemProxyState = .off
            systemProxyObservedEnabled = false
            systemProxyObservedMatchesMClash = false
            systemProxyObservedAt = Date()
            if wasRecovering {
                errorMessage = nil
            }
            appendSupervisorLog("System proxy restored to its previous state.")
            return true
        } catch {
            let message = error.localizedDescription
            systemProxyState = .failed(message)
            errorMessage = message
            appendSupervisorLog("System proxy restoration failed: \(message)")
            return false
        }
    }

    @discardableResult
    func shutdown() async -> Bool {
        let recoveryWasArmed = networkEnvironmentRecoveryArmed
        stopNetworkEnvironmentMonitoring()
        shutdownInProgress = true
        subscriptionUpdateTask?.cancel()
        subscriptionUpdateTask = nil
        systemProxyGuardTask?.cancel()
        systemProxyGuardTask = nil
        guard await cancelStartupPreparation(timeout: 30) else {
            let message = AppLocalization.string(
                "MClash is still finishing startup activation. Quit was cancelled so macOS network state cannot be abandoned mid-transaction."
            )
            errorMessage = message
            appendSupervisorLog(message)
            shutdownInProgress = false
            resumeNetworkEnvironmentMonitoringAfterCancelledShutdown(
                recoveryWasArmed: recoveryWasArmed
            )
            return false
        }
        guard await waitForNetworkOperationsToSettle() else {
            let message = AppLocalization.string(
                "MClash is still finishing a network settings transaction. Quit was cancelled so that transaction cannot restart a provider or core after cleanup."
            )
            errorMessage = message
            appendSupervisorLog(message)
            shutdownInProgress = false
            resumeNetworkEnvironmentMonitoringAfterCancelledShutdown(
                recoveryWasArmed: recoveryWasArmed
            )
            return false
        }
        shouldReenableSystemProxyAfterCrash = false
        if let operation = systemProxyEnableOperation {
            await operation.task.value
        }
        if networkCaptureIsActive,
           !(await performNetworkCaptureDeactivation()) {
            shutdownInProgress = false
            resumeNetworkEnvironmentMonitoringAfterCancelledShutdown(
                recoveryWasArmed: recoveryWasArmed
            )
            return false
        }
        if systemProxyEnabled || hasSystemProxySnapshot {
            guard await performDisableSystemProxy() else {
                // Keep the failure user-recoverable without allowing another Scene
                // task to begin an automatic restore/authorization loop.
                if hasSystemProxySnapshot { prepared = true }
                shutdownInProgress = false
                resumeNetworkEnvironmentMonitoringAfterCancelledShutdown(
                    recoveryWasArmed: recoveryWasArmed
                )
                return false
            }
        }
        let auxiliaryStops = await coreFleet.stopAll()
        auxiliaryCoreStates = await coreFleet.states()
        guard auxiliaryStops.values.allSatisfy({ $0 }) else {
            let failedProfiles = auxiliaryStops
                .filter { !$0.value }
                .keys
                .map(profileDisplayName)
                .sorted()
                .joined(separator: ", ")
            let message = failedProfiles.isEmpty
                ? AppLocalization.string(
                    "One or more auxiliary profile sessions could not be stopped."
                )
                : AppLocalization.format(
                    "These auxiliary profile sessions could not be stopped: %@.",
                    failedProfiles
                )
            errorMessage = message
            appendSupervisorLog(message)
            shutdownInProgress = false
            resumeNetworkEnvironmentMonitoringAfterCancelledShutdown(
                recoveryWasArmed: recoveryWasArmed
            )
            return false
        }
        guard await stopCore() else {
            shutdownInProgress = false
            resumeNetworkEnvironmentMonitoringAfterCancelledShutdown(
                recoveryWasArmed: recoveryWasArmed
            )
            return false
        }
        return true
    }

    func forceShutdown() async {
        stopNetworkEnvironmentMonitoring()
        shutdownInProgress = true
        subscriptionUpdateTask?.cancel()
        subscriptionUpdateTask = nil
        systemProxyGuardTask?.cancel()
        systemProxyGuardTask = nil
        _ = await cancelStartupPreparation(timeout: 2)
        let operationsSettled = await waitForNetworkOperationsToSettle(
            timeout: 2
        )
        if !operationsSettled {
            appendSupervisorLog(
                "Forced shutdown timed out waiting for a network settings transaction; final cleanup will proceed with all new activation paths disabled."
            )
        }
        shouldReenableSystemProxyAfterCrash = false
        systemProxyEnableOperation?.task.cancel()
        networkCaptureActivationOperation?.task.cancel()
        networkCaptureDeactivationOperation?.task.cancel()

        let extensionDisable = Task { [networkExtensionControl] in
            do {
                try await networkExtensionControl.disable()
                return true
            } catch {
                return false
            }
        }
        if await waitForTask(extensionDisable, timeout: 5) != true {
            appendSupervisorLog(
                "Forced shutdown could not confirm Network Extension cleanup before the hard deadline."
            )
        } else {
            networkCaptureState = .off
        }

        if systemProxyEnabled || hasSystemProxySnapshot
            || systemProxyEnableOperation != nil {
            let proxyRestore = Task { @MainActor [weak self] in
                guard let self else { return false }
                return await self.performDisableSystemProxy()
            }
            if await waitForTask(proxyRestore, timeout: 5) != true {
                appendSupervisorLog(
                    "Forced shutdown could not confirm macOS System Proxy restoration before the hard deadline."
                )
            }
        }
        let fleetStop = Task { [coreFleet] in
            await coreFleet.forceStopAll()
        }
        if await waitForTask(fleetStop, timeout: 5) == nil {
            appendSupervisorLog(
                "Forced shutdown queued auxiliary core cleanup but did not wait past the hard deadline."
            )
        } else {
            auxiliaryCoreStates = await coreFleet.states()
        }
        let primaryStop = Task { [supervisor] in
            await supervisor.stop()
        }
        if await waitForTask(primaryStop, timeout: 5) != true {
            appendSupervisorLog(
                "Forced shutdown could not confirm primary core cleanup before the hard deadline."
            )
        } else {
            coreState = await supervisor.state()
        }
        stopControllerStreams()
    }

    private func cancelStartupPreparation(
        timeout: TimeInterval
    ) async -> Bool {
        guard let operation = preparationOperation else { return true }
        operation.task.cancel()
        guard await waitForTask(operation.task, timeout: timeout) != nil else {
            return false
        }
        if preparationOperation?.id == operation.id {
            preparationOperation = nil
        }
        return true
    }

    private func waitForNetworkOperationsToSettle(
        timeout: TimeInterval = 30
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while operations.contains(where: {
            $0.serializesNetworkState || $0.isCoreBound
        }) {
            guard Date() < deadline else { return false }
            do {
                try await Task.sleep(for: .milliseconds(25))
            } catch {
                return false
            }
        }
        return true
    }

    private func waitForTask<Value: Sendable>(
        _ task: Task<Value, Never>,
        timeout: TimeInterval
    ) async -> Value? {
        await withCheckedContinuation { continuation in
            let gate = OneShotContinuation<Value?>(continuation)
            Task { @MainActor in
                let value = await task.value
                await gate.resume(returning: value)
            }
            Task {
                let milliseconds = max(1, Int(timeout * 1_000))
                try? await Task.sleep(for: .milliseconds(milliseconds))
                await gate.resume(returning: nil)
            }
        }
    }

    func clearLogs() {
        coreLogFlushTask?.cancel()
        coreLogFlushTask = nil
        pendingCoreLogs.removeAll(keepingCapacity: true)
        logs.removeAll(keepingCapacity: true)
    }

    func clearClosedConnectionHistory() {
        recentlyClosedConnections.removeAll(keepingCapacity: true)
        scheduleFlowLedgerRefresh()
    }

    @discardableResult
    func clearAppRoutingActivity() async -> Bool {
        do {
            var acknowledgedDroppedBefore: UInt64 = 0
            if networkCaptureIsActive {
                try await networkExtensionControl.clearAppRoutingActivity()
                acknowledgedDroppedBefore = (try? await networkExtensionControl
                    .appRoutingActivity(after: .max, limit: 1)
                    .droppedBeforeSequence) ?? 0
            }
            appRoutingActivities.removeAll(keepingCapacity: true)
            appRoutingActivitiesByIdentifier.removeAll(keepingCapacity: true)
            appRoutingRuleStatistics.removeAll(keepingCapacity: true)
            appRoutingActivityCursor = 0
            appRoutingActivityAcknowledgedDroppedBefore = acknowledgedDroppedBefore
            appRoutingActivityError = nil
            appRoutingTrafficRateTracker.reset()
            appRoutingTrafficRates = .zero
            appRoutingActiveCount = 0
            appRoutingActivityDroppedCount = 0
            appRoutingActivityCoverageStartedAt = Date()
            scheduleFlowLedgerRefresh()
            return true
        } catch {
            appRoutingActivityError = error.localizedDescription
            return false
        }
    }

    func setPersistentTrafficHistoryEnabled(_ enabled: Bool) async {
        await beginTrafficHistoryMutation()
        defer { endTrafficHistoryMutation() }
        guard !Task.isCancelled, !shutdownInProgress else { return }

        trafficHistoryPersistenceOperationGeneration &+= 1
        let operationGeneration = trafficHistoryPersistenceOperationGeneration
        trafficHistoryPersistenceTransitionInProgress = true
        defer {
            if operationGeneration == trafficHistoryPersistenceOperationGeneration {
                trafficHistoryPersistenceTransitionInProgress = false
                if persistentTrafficHistoryStore == nil {
                    queuedTrafficHistoryCompletions.removeAll(keepingCapacity: false)
                    queuedTrafficHistoryIdentifiers.removeAll(keepingCapacity: false)
                }
                startFlowLedgerRefreshIfNeeded()
                startPersistentTrafficHistoryWriterIfNeeded()
            }
        }
        trafficHistoryPersistenceChoice = enabled ? .persistent : .sessionOnly
        trafficHistoryLastPrunedAt = nil
        queuedTrafficHistoryCompletions.removeAll(keepingCapacity: false)
        queuedTrafficHistoryIdentifiers.removeAll(keepingCapacity: false)
        persistedTrafficHistoryIdentifiers.removeAll(keepingCapacity: false)
        persistedTrafficHistoryIdentifierOrder.removeAll(keepingCapacity: false)
        persistentTrafficHistoryStore = nil
        let writer = invalidateTrafficHistoryWriter()
        let writerGeneration = trafficHistoryPersistGeneration
        if let writer {
            await writer.value
        }
        guard operationGeneration == trafficHistoryPersistenceOperationGeneration else {
            return
        }
        if trafficHistoryPersistDrainGeneration == writerGeneration {
            trafficHistoryPersistDrainTask = nil
            trafficHistoryPersistDrainGeneration = nil
        }
        guard enabled else {
            trafficHistoryTodaySnapshot = nil
            trafficHistoryWeekSnapshot = nil
            trafficHistoryRuntimeState = .sessionOnly
            return
        }
        await openPersistentTrafficHistory(operationGeneration: operationGeneration)
    }

    func setTrafficHistoryRetention(_ retention: TrafficHistoryRetention) async {
        await beginTrafficHistoryMutation()
        defer { endTrafficHistoryMutation() }
        guard !Task.isCancelled, !shutdownInProgress else { return }

        guard !trafficHistoryClearInProgress,
              !trafficHistoryPersistenceTransitionInProgress else { return }
        trafficHistoryPersistenceOperationGeneration &+= 1
        let operationGeneration = trafficHistoryPersistenceOperationGeneration
        trafficHistoryPersistenceTransitionInProgress = true
        defer {
            if operationGeneration == trafficHistoryPersistenceOperationGeneration {
                trafficHistoryPersistenceTransitionInProgress = false
                if persistentTrafficHistoryStore == nil {
                    queuedTrafficHistoryCompletions.removeAll(keepingCapacity: false)
                    queuedTrafficHistoryIdentifiers.removeAll(keepingCapacity: false)
                }
                startFlowLedgerRefreshIfNeeded()
                startPersistentTrafficHistoryWriterIfNeeded()
            }
        }
        guard trafficHistoryPersistenceChoice == .persistent else { return }
        guard let store = persistentTrafficHistoryStore else { return }
        let writer = invalidateTrafficHistoryWriter()
        let writerGeneration = trafficHistoryPersistGeneration
        if let writer {
            await writer.value
        }
        guard operationGeneration == trafficHistoryPersistenceOperationGeneration else {
            return
        }
        if trafficHistoryPersistDrainGeneration == writerGeneration {
            trafficHistoryPersistDrainTask = nil
            trafficHistoryPersistDrainGeneration = nil
        }
        let now = Date()
        do {
            try await store.setRetention(retention, now: now)
            guard operationGeneration == trafficHistoryPersistenceOperationGeneration,
                  trafficHistoryPersistenceChoice == .persistent else { return }
            trafficHistoryRetention = retention
            trafficHistoryLastPrunedAt = now
            await refreshPersistentTrafficHistorySnapshots(
                expectedOperationGeneration: operationGeneration
            )
        } catch {
            guard operationGeneration == trafficHistoryPersistenceOperationGeneration,
                  trafficHistoryPersistenceChoice == .persistent else { return }
            markPersistentTrafficHistoryUnavailable(
                AppLocalization.format(
                    "MClash could not update the traffic history retention period: %@",
                    error.localizedDescription
                )
            )
        }
    }

    @discardableResult
    func clearTrafficHistory() async -> Bool {
        await beginTrafficHistoryMutation()
        defer { endTrafficHistoryMutation() }
        guard !Task.isCancelled, !shutdownInProgress else { return false }

        guard !trafficHistoryClearInProgress else { return false }
        trafficHistoryPersistenceOperationGeneration &+= 1
        let operationGeneration = trafficHistoryPersistenceOperationGeneration
        trafficHistoryClearInProgress = true
        trafficHistoryPersistenceTransitionInProgress = false
        let ledgerTask = invalidateFlowLedgerRefresh()
        let writer = invalidateTrafficHistoryWriter()
        let writerGeneration = trafficHistoryPersistGeneration
        if let writer {
            await writer.value
        }
        if trafficHistoryPersistDrainGeneration == writerGeneration {
            trafficHistoryPersistDrainTask = nil
            trafficHistoryPersistDrainGeneration = nil
        }
        if let ledgerTask {
            await ledgerTask.value
        }
        guard operationGeneration == trafficHistoryPersistenceOperationGeneration else {
            trafficHistoryClearInProgress = false
            return false
        }
        queuedTrafficHistoryCompletions.removeAll(keepingCapacity: false)
        queuedTrafficHistoryIdentifiers.removeAll(keepingCapacity: false)

        if persistentTrafficHistoryStore == nil,
           trafficHistoryPersistenceChoice == .persistent {
            await openPersistentTrafficHistory(
                operationGeneration: operationGeneration,
                allowDuringClear: true
            )
            guard operationGeneration == trafficHistoryPersistenceOperationGeneration else {
                trafficHistoryClearInProgress = false
                return false
            }
        }

        clearClosedConnectionHistory()
        guard await clearAppRoutingActivity() else {
            guard operationGeneration == trafficHistoryPersistenceOperationGeneration else {
                trafficHistoryClearInProgress = false
                return false
            }
            trafficHistoryClearInProgress = false
            scheduleFlowLedgerRefresh(neededForAccounting: true)
            startPersistentTrafficHistoryWriterIfNeeded()
            return false
        }

        let persistentHistoryExpected = trafficHistoryPersistenceChoice == .persistent
        guard let store = persistentTrafficHistoryStore else {
            guard operationGeneration == trafficHistoryPersistenceOperationGeneration else {
                trafficHistoryClearInProgress = false
                return false
            }
            trafficHistoryClearInProgress = false
            scheduleFlowLedgerRefresh(neededForAccounting: true)
            return !persistentHistoryExpected
        }
        do {
            _ = try await store.clear()
            guard operationGeneration == trafficHistoryPersistenceOperationGeneration else {
                trafficHistoryClearInProgress = false
                return false
            }
            persistedTrafficHistoryIdentifiers.removeAll(keepingCapacity: true)
            persistedTrafficHistoryIdentifierOrder.removeAll(keepingCapacity: true)
            trafficHistoryLastPrunedAt = Date()
            await refreshPersistentTrafficHistorySnapshots(
                expectedOperationGeneration: operationGeneration
            )
            guard operationGeneration == trafficHistoryPersistenceOperationGeneration else {
                trafficHistoryClearInProgress = false
                return false
            }
            trafficHistoryClearInProgress = false
            scheduleFlowLedgerRefresh(neededForAccounting: true)
            return true
        } catch {
            guard operationGeneration == trafficHistoryPersistenceOperationGeneration else {
                trafficHistoryClearInProgress = false
                return false
            }
            trafficHistoryClearInProgress = false
            scheduleFlowLedgerRefresh(neededForAccounting: true)
            markPersistentTrafficHistoryUnavailable(
                AppLocalization.format(
                    "MClash could not clear the persistent traffic history: %@",
                    error.localizedDescription
                )
            )
            return false
        }
    }

    func refreshPersistentTrafficHistorySnapshots(
        expectedPersistenceGeneration: UInt64? = nil,
        expectedOperationGeneration: UInt64? = nil
    ) async {
        guard let store = persistentTrafficHistoryStore else { return }
        do {
            let today = try await store.snapshot(for: .today)
            let week = try await store.snapshot(for: .week)
            guard expectedPersistenceGeneration == nil
                || expectedPersistenceGeneration == trafficHistoryPersistGeneration,
                expectedOperationGeneration == nil
                || expectedOperationGeneration == trafficHistoryPersistenceOperationGeneration else {
                return
            }
            trafficHistoryTodaySnapshot = today
            trafficHistoryWeekSnapshot = week
            trafficHistoryRuntimeState = .ready(lastUpdatedAt: Date())
        } catch {
            guard expectedPersistenceGeneration == nil
                || expectedPersistenceGeneration == trafficHistoryPersistGeneration,
                expectedOperationGeneration == nil
                || expectedOperationGeneration == trafficHistoryPersistenceOperationGeneration else {
                return
            }
            markPersistentTrafficHistoryUnavailable(
                AppLocalization.format(
                    "MClash could not read the persistent traffic history: %@",
                    error.localizedDescription
                )
            )
        }
    }

    private func prepareTrafficHistoryPersistenceIfNeeded() async {
        await beginTrafficHistoryMutation()
        defer { endTrafficHistoryMutation() }
        guard !Task.isCancelled, !shutdownInProgress else { return }

        switch trafficHistoryPersistenceChoice {
        case .undecided:
            trafficHistoryRuntimeState = .notConfigured
        case .sessionOnly:
            trafficHistoryRuntimeState = .sessionOnly
        case .persistent:
            trafficHistoryPersistenceOperationGeneration &+= 1
            let operationGeneration = trafficHistoryPersistenceOperationGeneration
            trafficHistoryPersistenceTransitionInProgress = true
            defer {
                if operationGeneration == trafficHistoryPersistenceOperationGeneration {
                    trafficHistoryPersistenceTransitionInProgress = false
                    if persistentTrafficHistoryStore == nil {
                        queuedTrafficHistoryCompletions.removeAll(keepingCapacity: false)
                        queuedTrafficHistoryIdentifiers.removeAll(keepingCapacity: false)
                    }
                    startFlowLedgerRefreshIfNeeded()
                    startPersistentTrafficHistoryWriterIfNeeded()
                }
            }
            let writer = invalidateTrafficHistoryWriter()
            let writerGeneration = trafficHistoryPersistGeneration
            if let writer {
                await writer.value
            }
            if trafficHistoryPersistDrainGeneration == writerGeneration {
                trafficHistoryPersistDrainTask = nil
                trafficHistoryPersistDrainGeneration = nil
            }
            await openPersistentTrafficHistory(
                operationGeneration: operationGeneration
            )
        }
    }

    private func openPersistentTrafficHistory(
        operationGeneration: UInt64,
        allowDuringClear: Bool = false
    ) async {
        func isCurrentOperation() -> Bool {
            return operationGeneration == self.trafficHistoryPersistenceOperationGeneration
                && self.trafficHistoryPersistenceChoice == .persistent
        }

        guard isCurrentOperation(),
              allowDuringClear || !trafficHistoryClearInProgress else { return }
        guard let profileLayout else {
            markPersistentTrafficHistoryUnavailable(
                AppLocalization.string(
                    "The MClash Application Support directory is unavailable."
                )
            )
            return
        }
        trafficHistoryRuntimeState = .loading
        let result = await Task.detached(priority: .utility) {
            TrafficHistoryStore.open(layout: profileLayout)
        }.value
        guard isCurrentOperation() else { return }
        switch result {
        case let .ready(store):
            do {
                let retention = try await store.retention()
                guard isCurrentOperation() else { return }
                let now = Date()
                do {
                    try await store.prune(now: now)
                    guard isCurrentOperation() else { return }
                    trafficHistoryLastPrunedAt = now
                } catch {
                    guard isCurrentOperation() else { return }
                    appendSupervisorLog(
                        "Persistent traffic history maintenance was deferred: \(error.localizedDescription)"
                    )
                }
                guard isCurrentOperation() else { return }
                persistentTrafficHistoryStore = store
                trafficHistoryRetention = retention
                persistedTrafficHistoryIdentifiers.removeAll(keepingCapacity: false)
                persistedTrafficHistoryIdentifierOrder.removeAll(keepingCapacity: false)
                await refreshPersistentTrafficHistorySnapshots(
                    expectedOperationGeneration: operationGeneration
                )
                guard isCurrentOperation(), persistentTrafficHistoryStore != nil else { return }
                schedulePersistentTrafficHistory(from: flowLedger)
            } catch {
                guard isCurrentOperation() else { return }
                markPersistentTrafficHistoryUnavailable(
                    AppLocalization.format(
                        "MClash opened traffic history but could not verify it: %@",
                        error.localizedDescription
                    )
                )
            }
        case let .unavailable(reason):
            guard isCurrentOperation() else { return }
            markPersistentTrafficHistoryUnavailable(
                Self.trafficHistoryUnavailableDescription(reason)
            )
        }
    }

    private func markPersistentTrafficHistoryUnavailable(_ reason: String) {
        persistentTrafficHistoryStore = nil
        trafficHistoryLastPrunedAt = nil
        trafficHistoryRuntimeState = .unavailable(reason)
        appendSupervisorLog("Persistent traffic history is unavailable: \(reason)")
    }

    private static func trafficHistoryUnavailableDescription(
        _ reason: TrafficHistoryStoreUnavailableReason
    ) -> String {
        switch reason {
        case .cannotCreatePrivateDirectory:
            AppLocalization.string(
                "MClash could not create its private TrafficHistory directory."
            )
        case .cannotOpenDatabase:
            AppLocalization.string(
                "MClash could not open its local traffic history database."
            )
        case .corruptedDatabase:
            AppLocalization.string(
                "The local traffic history database failed its integrity check. It was left untouched for recovery."
            )
        case let .newerSchema(found, supported):
            AppLocalization.format(
                "Traffic history uses schema %@, but this version of MClash supports schema %@. The database was left untouched.",
                String(found),
                String(supported)
            )
        case .migrationFailed:
            AppLocalization.string(
                "MClash could not migrate the local traffic history database. It was left untouched."
            )
        }
    }

    @discardableResult
    private func recordClosedConnections(
        previous: MihomoConnectionSnapshot?,
        current: MihomoConnectionSnapshot?
    ) -> Bool {
        guard let previous else { return false }
        let currentIDs = Set(current?.connections.map(\.id) ?? [])
        let closed = previous.connections.filter { !currentIDs.contains($0.id) }
        guard !closed.isEmpty else { return false }

        let closedIDs = Set(closed.map(\.id))
        recentlyClosedConnections.removeAll { closedIDs.contains($0.connection.id) }
        let timestamp = Date()
        recentlyClosedConnections.insert(
            contentsOf: closed.map {
                ClosedConnectionRecord(connection: $0, closedAt: timestamp)
            },
            at: 0
        )
        if recentlyClosedConnections.count > 500 {
            recentlyClosedConnections.removeLast(recentlyClosedConnections.count - 500)
        }
        return true
    }

    private func receive(_ event: CoreEvent) {
        switch event {
        case let .stateChanged(state):
            if isConnected {
                switch state {
                case .validating, .starting, .stopped:
                    // `start` performs a validation pass before launching.
                    // Its buffered transitional events may arrive after the
                    // direct start call has already established a live session.
                    return
                default:
                    break
                }
            }
            coreState = state
            if case let .failed(message) = state {
                errorMessage = message
                if notificationsEnabled {
                    Task { [notificationCenter] in
                        await notificationCenter.post(
                            identifier: "mclash-core-failed",
                            title: AppLocalization.string("MClash Needs Attention"),
                            body: message
                        )
                    }
                }
                let shouldReenable = systemProxyEnabled
                stopControllerStreams()
                if networkCaptureIsActive {
                    Task { [weak self] in
                        _ = await self?.performNetworkCaptureDeactivation()
                    }
                }
                if shouldReenable || hasSystemProxySnapshot {
                    beginCrashSystemProxyRestore(reenableAfterRestart: shouldReenable)
                }
            }
            if case .stopped = state {
                shouldReenableSystemProxyAfterCrash = false
                stopControllerStreams()
                if networkCaptureIsActive {
                    Task { [weak self] in
                        _ = await self?.performNetworkCaptureDeactivation()
                    }
                }
                // A failed restore deliberately leaves the snapshot in place
                // for a user-initiated retry. The cleanup stop event must not
                // turn that durable recovery state into an authorization loop.
                if !systemProxyRecoveryRequired,
                   systemProxyEnabled || hasSystemProxySnapshot {
                    Task { [weak self] in await self?.performDisableSystemProxy() }
                }
            }
            if case let .running(session) = state {
                Task { [weak self] in await self?.handleRunningSession(session) }
            }
        case let .log(line):
            appendCoreLog(line)
        }
    }

    private func receive(_ event: CoreFleetEvent) {
        switch event {
        case let .stateChanged(profileID, state):
            auxiliaryCoreStates[profileID] = state
            switch state {
            case .running:
                invalidateProfileProxyWorkspace(
                    profileID,
                    state: .idle
                )
            case .validating, .starting, .stopping:
                invalidateProfileProxyWorkspace(
                    profileID,
                    state: .unavailable(.controllerTransitioning)
                )
            case .stopped:
                invalidateProfileProxyWorkspace(
                    profileID,
                    state: .unavailable(.controllerStopped)
                )
            case let .failed(message):
                invalidateProfileProxyWorkspace(
                    profileID,
                    state: .unavailable(.controllerFailed(message))
                )
            }
            if case let .failed(message) = state {
                appendSupervisorLog(
                    "Profile \(profileDisplayName(profileID)) core failed: \(message)"
                )
            }
        case let .log(profileID, line):
            guard !lightweightMode || presentationTelemetryPolicy.logs else { return }
            appendCoreLog(CoreLogLine(
                timestamp: line.timestamp,
                stream: line.stream,
                message: "[\(profileDisplayName(profileID))] \(line.message)"
            ))
        }
    }

    private func profileDisplayName(_ profileID: ProfileID) -> String {
        profiles.first(where: { $0.id == profileID })?.name ?? profileID.description
    }

    private func verifyProfileRouteListenerProtocols(
        profileID: ProfileID
    ) async throws {
        let listeners = profileRouteListeners(for: profileID).filter(\.enabled)
        let httpPorts = Set(listeners.compactMap { listener in
            listener.protocolType == .http || listener.protocolType == .mixed
                ? listener.port
                : nil
        })
        let socksPorts = Set(listeners.compactMap { listener in
            listener.protocolType == .socks || listener.protocolType == .mixed
                ? listener.port
                : nil
        })
        guard !httpPorts.isEmpty || !socksPorts.isEmpty else { return }
        try await localPortProbe.waitUntilProxyProtocols(
            httpPorts: httpPorts,
            socksPorts: socksPorts
        )
    }

    private func validateProfileRouteListenerProxyTargets(
        profileID: ProfileID?,
        collection: MihomoProxyCollection
    ) throws {
        guard let profileID else { return }
        for listener in profileRouteListeners(for: profileID) where listener.enabled {
            let isAvailable: Bool
            switch listener.target {
            case .profileRules, .subRule, .global:
                isAvailable = true
            case let .policyGroup(name):
                if let proxy = collection.proxies[name] {
                    isAvailable = !proxy.all.isEmpty
                        || ProxyGroupKind(rawType: proxy.type).isKnownGroup
                } else {
                    isAvailable = false
                }
            case let .proxyNode(name):
                if let proxy = collection.proxies[name] {
                    isAvailable = proxy.all.isEmpty
                        && !ProxyGroupKind(rawType: proxy.type).isKnownGroup
                } else {
                    isAvailable = false
                }
            }
            guard isAvailable else {
                throw AppModelError.routeListenerTargetUnavailable(
                    listener.name,
                    listener.target.presentationName
                )
            }
        }
    }

    private func handleRunningSession(_ session: CoreSession) async {
        await controllerDidStart(session)
        if let networkCaptureDeactivationOperation {
            _ = await networkCaptureDeactivationOperation.task.value
        }
        if controllerIsReady, isConnected {
            setNetworkEnvironmentRecoveryArmed(true)
        }
        if controllerIsReady,
           isConnected,
           networkCapturePreferences.enabled,
           networkCaptureNeedsActivation {
            await performNetworkCaptureActivation()
        }
        guard shouldReenableSystemProxyAfterCrash,
              controllerIsReady,
              isConnected else { return }
        await enableSystemProxyAfterConnect(requiresCrashIntent: true)
    }

    private func enableSystemProxyAfterConnect(requiresCrashIntent: Bool = false) async {
        guard await completeCrashProxyRestoreIfNeeded() else { return }
        if requiresCrashIntent, !shouldReenableSystemProxyAfterCrash { return }
        guard isConnected,
              controllerIsReady,
              !networkCapturePreferences.enabled else { return }
        await performEnableSystemProxy()
        guard systemProxyState == .on else { return }
        shouldReenableSystemProxyAfterCrash = false
        guard configurationActivationRecoveryRequiresSystemProxy,
              let configurationStore else { return }
        do {
            try await configurationStore.clearActivationJournal()
            configurationActivationRecoveryRequiresSystemProxy = false
        } catch {
            appendSupervisorLog(
                AppLocalization.format(
                    "The completed MClash Workspace activation journal could not be cleared: %@",
                    error.localizedDescription
                )
            )
        }
    }

    private func beginCrashSystemProxyRestore(reenableAfterRestart: Bool) {
        if reenableAfterRestart {
            shouldReenableSystemProxyAfterCrash = true
        }
        guard crashProxyRestoreOperation == nil else { return }

        let id = UUID()
        let task = Task { [weak self] in
            guard let self else { return false }
            return await self.performDisableSystemProxy()
        }
        crashProxyRestoreOperation = (id, task)
    }

    private func completeCrashProxyRestoreIfNeeded() async -> Bool {
        guard let operation = crashProxyRestoreOperation else {
            return !systemProxyRecoveryRequired
        }
        let restored = await operation.task.value
        if crashProxyRestoreOperation?.id == operation.id {
            crashProxyRestoreOperation = nil
        }
        if !restored {
            shouldReenableSystemProxyAfterCrash = false
        }
        return restored
    }

    private func coreHomeDirectory() throws -> URL {
        if let profileLayout, let activeProfileID {
            try profileLayout.createRuntimeDirectories(for: activeProfileID)
            return profileLayout.coreHomeDirectory(for: activeProfileID)
        }
        let applicationRoot = profileLayout?.rootDirectory
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appending(path: "MClash", directoryHint: .isDirectory)
        let root = applicationRoot
            .appending(path: "CoreHome", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        return root
    }

    private func makeProfileValidator() throws -> ClosureProfileValidator {
        let binaryURL = try binaryLocator.locate()
        let homeDirectory = try validationHomeDirectory()
        try geoDataInstaller.installIfNeeded(into: homeDirectory)

        return ClosureProfileValidator { [supervisor] configurationURL in
            try await supervisor.validateWithoutStateChanges(
                CoreLaunchConfiguration(
                    binaryURL: binaryURL,
                    homeDirectory: homeDirectory,
                    configURL: configurationURL,
                    controllerPort: 0,
                    secret: ""
                )
            )
        }
    }

    private func validationHomeDirectory() throws -> URL {
        let applicationRoot = profileLayout?.rootDirectory
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appending(path: "MClash", directoryHint: .isDirectory)
        let root = applicationRoot
            .appending(path: "ValidationHome", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        return root
    }

    private func controllerDidStart(_ session: CoreSession) async {
        if activeControllerEndpoint == session.endpoint, controllerState == .ready {
            return
        }

        if let operation = controllerSetupOperation, operation.endpoint == session.endpoint {
            await operation.task.value
            return
        }

        controllerSetupOperation?.task.cancel()
        let id = UUID()
        let task = Task { [weak self] in
            guard let self else { return }
            await self.performControllerSetup(session)
        }
        controllerSetupOperation = (id, session.endpoint, task)
        await task.value
        if controllerSetupOperation?.id == id {
            controllerSetupOperation = nil
        }
    }

    private func performControllerSetup(_ session: CoreSession) async {
        controllerState = .loading
        activeControllerEndpoint = session.endpoint
        controllerGeneration &+= 1
        let generation = controllerGeneration
        do {
            let client = try MihomoAPIClient(baseURL: session.endpoint, secret: session.secret)
            let initialConfig = try await client.fetchConfig()
            let config = try await ensureLocalProxyListeners(
                initialConfig,
                using: client
            )
            let proxies = try await client.fetchProxies()
            try validateProfileRouteListenerProxyTargets(
                profileID: activeProfileID,
                collection: proxies
            )
            guard generation == controllerGeneration,
                  activeControllerEndpoint == session.endpoint,
                  isConnected else { return }
            apiClient = client
            runtimeConfig = config
            await refreshSystemProxyObservation()
            proxyProfileStructure = loadProxyProfileStructure()
            applyProxyCollection(proxies, profileStructure: proxyProfileStructure)
            await applyUnifiedGlobalSelectionIfNeeded(using: client)
            startControllerStreams(client, generation: generation)
            controllerState = .ready
            errorMessage = nil
            appendSupervisorLog("Connected to the local Alpha controller.")
            Task { [weak self] in
                await self?.loadRules(using: client, generation: generation)
            }
        } catch {
            guard generation == controllerGeneration,
                  activeControllerEndpoint == session.endpoint,
                  isConnected else { return }
            controllerState = .degraded(error.localizedDescription)
            errorMessage = error.localizedDescription
        }
    }

    private func applyUnifiedGlobalSelectionIfNeeded(
        using client: MihomoAPIClient
    ) async {
        guard unifiedConfigurationEnabled,
              let workspace = configurationDocument.currentWorkspace,
              workspace.routingMode == .global,
              let targetID = workspace.globalProxyGroupID
                    ?? workspace.proxyGroupIDs.first,
              let targetName = configurationDocument.proxyGroups.first(where: {
                  $0.id == targetID && $0.enabled
              })?.name else {
            return
        }
        do {
            try await client.selectProxy(group: "GLOBAL", proxy: targetName)
            let refreshed = try await client.fetchProxies()
            guard isConnected else { return }
            applyProxyCollection(refreshed, profileStructure: proxyProfileStructure)
        } catch {
            // A missing GLOBAL selector should be visible in the live proxy
            // surface, but it must not make a healthy core fail to start.
            appendSupervisorLog(
                "MClash could not apply the saved Global exit: \(error.localizedDescription)"
            )
        }
    }

    /// Reads the current macOS proxy dictionaries without writing them. The
    /// result is used to distinguish MClash's state machine from an externally
    /// enabled proxy that survived an upgrade or belongs to another tool.
    func refreshSystemProxyObservation() async {
        do {
            let snapshot = try await systemProxyManager.captureSnapshot()
            let enabled = snapshot.services.contains { state in
                guard let configuration = state.configuration else { return false }
                return Self.proxyValueIsEnabled(configuration[SystemProxyKeys.httpEnable])
                    || Self.proxyValueIsEnabled(configuration[SystemProxyKeys.httpsEnable])
                    || Self.proxyValueIsEnabled(configuration[SystemProxyKeys.socksEnable])
                    || Self.proxyValueIsEnabled(configuration[SystemProxyKeys.pacEnable])
                    || Self.proxyValueIsEnabled(configuration[SystemProxyKeys.autoDiscoveryEnable])
            }
            guard let endpoints = currentSystemProxyEndpoints() else {
                systemProxyObservedEnabled = enabled
                systemProxyObservedMatchesMClash = false
                systemProxyObservedAt = Date()
                if enabled {
                    appendSupervisorLog(
                        "macOS system proxy is enabled, but MClash has no active listener to compare. MClash left it untouched."
                    )
                }
                return
            }
            let matches: Bool
            if enabled {
                matches = try await systemProxyManager.configurationMatches(
                    endpoints: endpoints,
                    bypassDomains: systemProxyPreferences.effectiveBypassDomains
                )
            } else {
                matches = false
            }
            systemProxyObservedEnabled = enabled
            systemProxyObservedMatchesMClash = matches
            systemProxyObservedAt = Date()
            if enabled && !matches {
                appendSupervisorLog(
                    "macOS system proxy is enabled externally and does not match MClash's current listener. MClash left it untouched."
                )
            } else if enabled && matches && systemProxyState == .off {
                appendSupervisorLog(
                    "macOS system proxy matches the MClash listener, but no MClash ownership snapshot is available."
                )
            }
        } catch {
            systemProxyObservedAt = Date()
            appendSupervisorLog(
                "MClash could not observe the macOS system proxy state: \(error.localizedDescription)"
            )
        }
    }

    private static func proxyValueIsEnabled(
        _ value: SystemProxyPropertyValue?
    ) -> Bool {
        switch value {
        case let .integer(number): number == 1
        case let .bool(value): value
        default: false
        }
    }

    private func ensureLocalProxyListeners(
        _ initialConfig: MihomoConfig,
        using client: MihomoAPIClient
    ) async throws -> MihomoConfig {
        managedMixedPort = nil
        let requestedMixedPort = activeProfileID == nil
            ? runtimeOverrides.ports.mixedPort
            : profileRuntimePlan.defaultMixedPort
        let requiresExactListeners = requestedMixedPort != nil
        if let port = positivePort(initialConfig.mixedPort) {
            // A unified runtime owns this endpoint. If mihomo came up with a
            // stale source/legacy port, repair it in place before probing the
            // listener instead of treating the mismatch as a missing port.
            if let requested = requestedMixedPort, requested != port {
                do {
                    try await client.patchConfig(
                        MihomoConfigPatch(mixedPort: requested)
                    )
                    let config = try await client.fetchConfig()
                    guard config.mixedPort == requested else {
                        throw AppModelError.localProxyOverrideRejected(requested)
                    }
                    try await localPortProbe.waitUntilProxyProtocols(
                        httpPort: requested,
                        socksPort: requested
                    )
                    if let dedicatedPort = activeProfileDedicatedMixedListener.map({
                        Int($0.port)
                    }) {
                        try await localPortProbe.waitUntilProxyProtocols(
                            httpPort: dedicatedPort,
                            socksPort: dedicatedPort
                        )
                    }
                    if let activeProfileID {
                        try await verifyProfileRouteListenerProtocols(
                            profileID: activeProfileID
                        )
                    }
                    return config
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    if requiresExactListeners {
                        throw AppModelError.explicitLocalProxyListenersUnavailable(
                            [requested]
                        )
                    }
                }
            }
            do {
                try await localPortProbe.waitUntilProxyProtocols(
                    httpPort: port,
                    socksPort: port
                )
                if let requested = requestedMixedPort,
                   requested != port {
                    throw AppModelError.explicitLocalProxyListenerRejected(
                        field: "Mixed",
                        requested: requested,
                        actual: initialConfig.mixedPort
                    )
                }
                if let dedicatedPort = activeProfileDedicatedMixedListener.map({
                    Int($0.port)
                }) {
                    try await localPortProbe.waitUntilProxyProtocols(
                        httpPort: dedicatedPort,
                        socksPort: dedicatedPort
                    )
                }
                if let activeProfileID {
                    try await verifyProfileRouteListenerProtocols(
                        profileID: activeProfileID
                    )
                }
                return initialConfig
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                if requiresExactListeners {
                    throw AppModelError.explicitLocalProxyListenersUnavailable(
                        [port]
                    )
                }
                appendSupervisorLog(
                    "Configured proxy listeners were unavailable; applying a temporary MClash mixed port."
                )
            }
        } else {
            if requiresExactListeners {
                // Source profiles are intentionally node-only and commonly do
                // not define a Mixed port. The unified runtime supplies it;
                // if mihomo did not load that override, repair the endpoint
                // through the authenticated controller before failing.
                if let requested = requestedMixedPort {
                    do {
                        try await client.patchConfig(
                            MihomoConfigPatch(mixedPort: requested)
                        )
                        let config = try await client.fetchConfig()
                        guard config.mixedPort == requested else {
                            throw AppModelError.localProxyOverrideRejected(requested)
                        }
                        try await localPortProbe.waitUntilProxyProtocols(
                            httpPort: requested,
                            socksPort: requested
                        )
                        if let dedicatedPort = activeProfileDedicatedMixedListener.map({
                            Int($0.port)
                        }) {
                            try await localPortProbe.waitUntilProxyProtocols(
                                httpPort: dedicatedPort,
                                socksPort: dedicatedPort
                            )
                        }
                        if let activeProfileID {
                            try await verifyProfileRouteListenerProtocols(
                                profileID: activeProfileID
                            )
                        }
                        return config
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        throw AppModelError.explicitLocalProxyListenersUnavailable(
                            [requested]
                        )
                    }
                }
            }
            appendSupervisorLog(
                "The profile has no usable Mixed listener; applying a temporary MClash mixed port."
            )
        }

        var lastError: Error?
        for _ in 0..<3 {
            let port = try localPortProbe.availableTCPPort()
            do {
                try await client.patchConfig(MihomoConfigPatch(mixedPort: port))
                let config = try await client.fetchConfig()
                guard config.mixedPort == port else {
                    throw AppModelError.localProxyOverrideRejected(port)
                }
                try await localPortProbe.waitUntilProxyProtocols(
                    httpPort: port,
                    socksPort: port
                )
                managedMixedPort = port
                appendSupervisorLog("MClash local HTTP/SOCKS5 listener is ready on 127.0.0.1:\(port).")
                return config
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
            }
        }

        throw lastError ?? AppModelError.localProxyPortsUnavailable
    }

    private func refreshProxyGroups(generation: Int) async {
        guard let apiClient else { return }
        let revision = nextProxyRefreshRevision()
        do {
            let proxies = try await apiClient.fetchProxies()
            guard generation == controllerGeneration,
                  revision == proxyRefreshRevision,
                  isConnected else { return }
            applyProxyCollection(proxies, profileStructure: proxyProfileStructure)
        } catch {
            guard generation == controllerGeneration,
                  revision == proxyRefreshRevision,
                  isConnected else { return }
            errorMessage = error.localizedDescription
        }
    }

    private func resolveProfileProxyController(
        for profileID: ProfileID
    ) async -> ProfileProxyControllerResolution {
        if let profileProxyControllerResolverOverride {
            return await profileProxyControllerResolverOverride(profileID)
        }
        guard profiles.contains(where: { $0.id == profileID }) else {
            return .unavailable(.profileNotFound)
        }
        if profileID == activeProfileID {
            guard isConnected, controllerIsReady, let apiClient else {
                return .unavailable(.primaryControllerNotReady)
            }
            return .available(apiClient)
        }
        guard let sessionSpec = profileSessionSpec(for: profileID),
              sessionSpec.enabled else {
            return .unavailable(.dedicatedPortDisabled(
                port: profileSessionSpec(for: profileID)?.mixedPort
            ))
        }
        switch await coreFleet.state(for: profileID) {
        case let .running(session)?:
            do {
                return .available(try MihomoAPIClient(
                    baseURL: session.endpoint,
                    secret: session.secret
                ))
            } catch {
                return .unavailable(.controllerFailed(
                    error.localizedDescription
                ))
            }
        case let .failed(message)?:
            return .unavailable(.controllerFailed(message))
        case .validating?, .starting?, .stopping?:
            return .unavailable(.controllerTransitioning)
        case .stopped?, nil:
            return .unavailable(.controllerStopped)
        }
    }

    private func profileProxyOperationContext(
        for profileID: ProfileID
    ) async -> (
        client: MihomoAPIClient,
        snapshot: ProfileProxyWorkspaceSnapshot
    )? {
        var snapshot = profileProxyWorkspaceState(for: profileID).snapshot
        if snapshot == nil {
            snapshot = await refreshProxyWorkspace(for: profileID).snapshot
        }
        guard let snapshot else { return nil }
        guard case let .available(client) = await resolveProfileProxyController(
            for: profileID
        ) else {
            _ = await refreshProxyWorkspace(for: profileID)
            return nil
        }
        return (client, snapshot)
    }

    private func loadProxyProfileStructure(
        for profileID: ProfileID
    ) async -> ProfileStructure {
        guard let profileStore,
              let data = try? await profileStore.configurationData(
                  for: profileID
              ) else {
            return .empty
        }
        return ProfileStructureReader().read(data: data)
    }

    private func nextProfileProxyWorkspaceRevision(
        for profileID: ProfileID
    ) -> UInt64 {
        let revision = (profileProxyWorkspaceRevisions[profileID] ?? 0) &+ 1
        profileProxyWorkspaceRevisions[profileID] = revision
        return revision
    }

    private func invalidateProfileProxyWorkspace(
        _ profileID: ProfileID,
        state: ProfileProxyWorkspaceState
    ) {
        _ = nextProfileProxyWorkspaceRevision(for: profileID)
        profileProxyWorkspaceStates[profileID] = state
    }

    private func profileProxyWorkspaceRevision(
        for profileID: ProfileID,
        matches revision: UInt64
    ) -> Bool {
        profileProxyWorkspaceRevisions[profileID] == revision
    }

    private func synchronizeLegacyProxyStateIfNeeded(
        _ snapshot: ProfileProxyWorkspaceSnapshot
    ) {
        guard snapshot.profileID == activeProfileID else { return }
        runtimeConfig = snapshot.runtimeConfig
        applyProxyCollection(
            MihomoProxyCollection(proxies: snapshot.proxiesByName),
            profileStructure: snapshot.profileStructure
        )
    }

    private func updateProfileProxyWorkspaceDelays(
        profileID: ProfileID,
        snapshot: ProfileProxyWorkspaceSnapshot
    ) {
        let refreshed = ProfileProxyWorkspaceSnapshotBuilder().build(
            profileID: profileID,
            runtimeConfig: snapshot.runtimeConfig,
            collection: MihomoProxyCollection(
                proxies: snapshot.proxiesByName
            ),
            profileStructure: snapshot.profileStructure,
            measuredDelays: profileProxyMeasuredDelays[profileID] ?? [:]
        )
        profileProxyWorkspaceStates[profileID] = .ready(refreshed)
    }

    private func failProfileProxyWorkspace(
        _ profileID: ProfileID,
        error: any Error,
        context: String
    ) {
        profileProxyWorkspaceStates[profileID] = .failed(
            message: error.localizedDescription,
            previous: profileProxyWorkspaceStates[profileID]?.snapshot
        )
        recordOperationFailure(error, context: context)
    }

    private func delayTarget(
        forProxy proxy: String,
        group groupName: String?,
        snapshot: ProfileProxyWorkspaceSnapshot
    ) -> URL? {
        if let groupName,
           let group = snapshot.proxiesByName[groupName],
           let target = delayTarget(for: group) {
            return target
        }
        if let proxyModel = snapshot.proxiesByName[proxy],
           let target = delayTarget(for: proxyModel) {
            return target
        }
        if let group = snapshot.proxyGroups.first(where: {
            $0.all.contains(proxy)
        }),
        let target = delayTarget(for: group) {
            return target
        }
        return defaultDelayTarget
    }

    private func expectedDelayStatus(
        forProxy proxy: String,
        group groupName: String?,
        snapshot: ProfileProxyWorkspaceSnapshot
    ) -> String? {
        if let groupName,
           let group = snapshot.proxiesByName[groupName],
           let status = normalizedExpectedStatus(group.expectedStatus) {
            return status
        }
        if let status = normalizedExpectedStatus(
            snapshot.proxiesByName[proxy]?.expectedStatus
        ) {
            return status
        }
        let group = snapshot.proxyGroups.first { $0.all.contains(proxy) }
        return normalizedExpectedStatus(group?.expectedStatus)
    }

    private func closeProfileConnectionsAfterRoutingChange(
        using client: MihomoAPIClient,
        profileID: ProfileID
    ) async {
        guard closeConnectionsOnRoutingChange else { return }
        do {
            try await client.closeAllConnections()
            appendSupervisorLog(
                "Closed existing \(profileDisplayName(profileID)) connections after the routing selection changed."
            )
        } catch {
            let message = AppLocalization.format(
                "%@ routing changed, but existing connections could not be closed: %@",
                profileDisplayName(profileID),
                error.localizedDescription
            )
            errorMessage = message
            appendSupervisorLog(message)
        }
    }

    private func closeConnectionsAfterRoutingChange(
        using client: MihomoAPIClient,
        generation: Int
    ) async {
        guard closeConnectionsOnRoutingChange else { return }
        do {
            try await client.closeAllConnections()
            guard generation == controllerGeneration, isConnected else { return }
            appendSupervisorLog("Closed existing connections after the routing selection changed.")
        } catch {
            guard generation == controllerGeneration, isConnected else { return }
            let message = AppLocalization.format(
                "Routing changed, but existing connections could not be closed: %@",
                error.localizedDescription
            )
            errorMessage = message
            appendSupervisorLog(message)
        }
    }

    private func loadRules(using client: MihomoAPIClient, generation: Int) async {
        do {
            let collection = try await client.fetchRules()
            guard generation == controllerGeneration, isConnected else { return }
            rules = collection.rules
            rulesErrorMessage = nil
            rulesLastLoadedAt = Date()
        } catch {
            guard !Task.isCancelled else { return }
            guard generation == controllerGeneration, isConnected else { return }
            rulesErrorMessage = error.localizedDescription
            appendSupervisorLog("Rules could not be loaded: \(error.localizedDescription)")
        }
    }

    private func loadProviders(using client: MihomoAPIClient, generation: Int) async {
        var failures: [String] = []
        var loadedAtLeastOneCollection = false

        do {
            let proxyCollection = try await client.fetchProxyProviders()
            guard !Task.isCancelled,
                  generation == controllerGeneration,
                  isConnected else { return }
            proxyProviders = proxyCollection.providers.values.sorted {
                $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
            loadedAtLeastOneCollection = true
        } catch {
            guard !Task.isCancelled,
                  generation == controllerGeneration,
                  isConnected else { return }
            failures.append(
                AppLocalization.format(
                    "Proxy providers: %@",
                    error.localizedDescription
                )
            )
        }

        do {
            let ruleCollection = try await client.fetchRuleProviders()
            guard !Task.isCancelled,
                  generation == controllerGeneration,
                  isConnected else { return }
            ruleProviders = ruleCollection.providers.values.sorted {
                $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
            loadedAtLeastOneCollection = true
        } catch {
            guard !Task.isCancelled,
                  generation == controllerGeneration,
                  isConnected else { return }
            failures.append(
                AppLocalization.format(
                    "Rule providers: %@",
                    error.localizedDescription
                )
            )
        }

        guard !Task.isCancelled,
              generation == controllerGeneration,
              isConnected else { return }
        if failures.isEmpty {
            providersErrorMessage = nil
        } else {
            let message = failures.joined(separator: "\n")
            providersErrorMessage = message
            appendSupervisorLog("Providers could not be fully loaded: \(message)")
        }
        if loadedAtLeastOneCollection {
            providersLastLoadedAt = Date()
        }
    }

    private func startControllerStreams(_ client: MihomoAPIClient, generation: Int) {
        cancelControllerStreamTasks()
        degradedStreams = []
        reconcileControllerTelemetry(
            client: client,
            generation: generation
        )
    }

    private func presentationDemandDidChange() {
        reconcileControllerTelemetry()
        if case .on = networkCaptureState {
            launchAppRoutingActivityMonitor()
        }
        if presentationTelemetryPolicy.appRoutingActivity {
            scheduleFlowLedgerRefresh()
        } else {
            cancelPresentationFlowLedgerRefresh()
        }
    }

    private func reconcileControllerTelemetry(
        client providedClient: MihomoAPIClient? = nil,
        generation providedGeneration: Int? = nil
    ) {
        let policy = presentationTelemetryPolicy
        supervisor.setProcessLogForwardingEnabled(policy.logs)
        Task { [coreFleet] in
            await coreFleet.setProcessLogForwardingEnabledForAll(policy.logs)
        }
        guard isConnected,
              let client = providedClient ?? apiClient else {
            cancelControllerStreamTasks()
            return
        }
        let generation = providedGeneration ?? controllerGeneration

        reconcileControllerStream(
            .traffic,
            shouldRun: policy.traffic,
            task: &trafficTask
        ) {
            Task { [weak self] in
                await self?.monitorTraffic(client, generation: generation)
            }
        }
        let connectionIntervalMilliseconds = policy.connections ? 1_000 : 5_000
        if connectionsTask != nil,
           connectionStreamIntervalMilliseconds != connectionIntervalMilliseconds {
            connectionsTask?.cancel()
            connectionsTask = nil
            connectionStreamIntervalMilliseconds = nil
        }
        reconcileControllerStream(
            .connections,
            // Lightweight mode deliberately trades background traffic-history
            // completeness for lower steady-state CPU and wakeups. Opening a
            // surface that needs connection data immediately resumes the feed.
            shouldRun: policy.connections || !lightweightMode,
            task: &connectionsTask
        ) {
            connectionStreamIntervalMilliseconds = connectionIntervalMilliseconds
            return Task { [weak self] in
                await self?.monitorConnections(
                    client,
                    generation: generation,
                    intervalMilliseconds: connectionIntervalMilliseconds
                )
            }
        }
        reconcileControllerStream(
            .logs,
            shouldRun: policy.logs,
            task: &apiLogTask
        ) {
            Task { [weak self] in
                await self?.monitorLogs(client, generation: generation)
            }
        }
        reconcileControllerStream(
            .proxies,
            shouldRun: policy.proxies,
            task: &proxyRefreshTask
        ) {
            Task { [weak self] in
                await self?.monitorProxyState(client, generation: generation)
            }
        }

        if policy.hasControllerStreams {
            if liveFreshnessWatchdogTask == nil {
                startLiveFreshnessWatchdog(generation: generation)
            }
        } else {
            liveFreshnessWatchdogTask?.cancel()
            liveFreshnessWatchdogTask = nil
        }
    }

    private func reconcileControllerStream(
        _ stream: LiveStream,
        shouldRun: Bool,
        task: inout Task<Void, Never>?,
        start: () -> Task<Void, Never>
    ) {
        if shouldRun {
            guard task == nil else { return }
            liveStreamHealth[stream] = .connecting(
                previousSampleAt: liveStreamHealth[stream]?.lastReceivedAt
            )
            task = start()
            return
        }

        guard task != nil || liveStreamHealth[stream]?.phase != .inactive else { return }
        task?.cancel()
        task = nil
        degradedStreams.remove(stream)
        liveStreamHealth[stream] = .inactive
    }

    private func startLiveFreshnessWatchdog(generation: Int) {
        liveFreshnessWatchdogTask?.cancel()
        liveFreshnessWatchdogTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(1))
                } catch {
                    return
                }
                guard let self, self.streamShouldContinue(generation) else { return }
                self.expireSilentLiveStreams(at: Date())
            }
        }
    }

    /// A connected WebSocket can stop producing samples without throwing.
    /// Expire data by cadence so a retained number never masquerades as live.
    func expireSilentLiveStreams(at now: Date = Date()) {
        let policy = presentationTelemetryPolicy
        let deadlines: [(LiveStream, TimeInterval)] = [
            policy.traffic ? (.traffic, 4) : nil,
            policy.connections ? (.connections, 6) : nil,
            policy.proxies ? (.proxies, 15) : nil,
            policy.appRoutingActivity ? (.appRouting, 5) : nil,
        ].compactMap { $0 }
        for (stream, deadline) in deadlines {
            guard var health = liveStreamHealth[stream],
                  health.phase == .live,
                  let lastReceivedAt = health.lastReceivedAt,
                  now.timeIntervalSince(lastReceivedAt) > deadline else {
                continue
            }
            let reason = AppLocalization.format(
                "No %@ sample was received for more than %@ seconds.",
                stream.freshnessDescription,
                String(Int(deadline))
            )
            health.becameStale(reason: reason, at: now)
            liveStreamHealth[stream] = health
            degradedStreams.insert(stream)
            appendSupervisorLog(reason)
        }
    }

    private func monitorProxyState(_ client: MihomoAPIClient, generation: Int) async {
        var consecutiveFailures = 0
        while streamShouldContinue(generation) {
            var requestRevision: Int?
            do {
                try await Task.sleep(for: .seconds(5))
                guard streamShouldContinue(generation) else { return }
                let revision = nextProxyRefreshRevision()
                requestRevision = revision
                let proxies = try await client.fetchProxies()
                guard streamShouldContinue(generation),
                      revision == proxyRefreshRevision else { continue }
                applyProxyCollection(proxies, profileStructure: proxyProfileStructure)
                markStreamHealthy(.proxies)
                consecutiveFailures = 0
            } catch is CancellationError {
                return
            } catch {
                guard streamShouldContinue(generation) else { return }
                guard requestRevision == proxyRefreshRevision else { continue }
                markStreamDegraded(
                    .proxies,
                    error: error,
                    attempt: consecutiveFailures + 1
                )
                if consecutiveFailures == 0 {
                    appendSupervisorLog(
                        "Proxy state refresh interrupted: \(error.localizedDescription)"
                    )
                }
                consecutiveFailures += 1
            }
        }
    }

    private func monitorTraffic(_ client: MihomoAPIClient, generation: Int) async {
        var attempt = 0
        while streamShouldContinue(generation) {
            do {
                let stream = try await client.trafficStream()
                for try await sample in stream {
                    guard streamShouldContinue(generation) else { return }
                    traffic = sample
                    trafficHistory.append(
                        TrafficSample(
                            timestamp: Date(),
                            download: sample.download,
                            upload: sample.upload
                        )
                    )
                    if trafficHistory.count > 60 {
                        trafficHistory.removeFirst(trafficHistory.count - 60)
                    }
                    markStreamHealthy(.traffic)
                    attempt = 0
                }
                guard streamShouldContinue(generation) else { return }
                throw AppModelError.streamEnded("Traffic")
            } catch is CancellationError {
                return
            } catch {
                guard streamShouldContinue(generation) else { return }
                markStreamDegraded(.traffic, error: error, attempt: attempt + 1)
                appendSupervisorLog("Traffic stream interrupted: \(error.localizedDescription)")
                attempt += 1
                if !(await waitBeforeStreamRetry(attempt, generation: generation)) { return }
            }
        }
    }

    private func monitorConnections(
        _ client: MihomoAPIClient,
        generation: Int,
        intervalMilliseconds: Int
    ) async {
        var attempt = 0
        while streamShouldContinue(generation) {
            do {
                let stream = try await client.connectionStream(
                    intervalMilliseconds: intervalMilliseconds
                )
                for try await snapshot in stream {
                    guard streamShouldContinue(generation) else { return }
                    let worker = Task.detached(priority: .utility) {
                        Self.normalizedConnectionSnapshot(snapshot)
                    }
                    let normalized = await withTaskCancellationHandler {
                        await worker.value
                    } onCancel: {
                        worker.cancel()
                    }
                    guard streamShouldContinue(generation) else { return }
                    applyConnectionSnapshot(normalized, generation: generation)
                    markStreamHealthy(.connections)
                    attempt = 0
                }
                guard streamShouldContinue(generation) else { return }
                throw AppModelError.streamEnded("Connection")
            } catch is CancellationError {
                return
            } catch {
                guard streamShouldContinue(generation) else { return }
                markStreamDegraded(.connections, error: error, attempt: attempt + 1)
                appendSupervisorLog("Connection stream interrupted: \(error.localizedDescription)")
                attempt += 1
                if !(await waitBeforeStreamRetry(attempt, generation: generation)) { return }
            }
        }
    }

    private func monitorLogs(_ client: MihomoAPIClient, generation: Int) async {
        var attempt = 0
        while streamShouldContinue(generation) {
            do {
                let stream = try await client.logStream(minimumLevel: .info)
                markStreamHealthy(.logs)
                var lastHealthPublication = Date()
                for try await entry in stream {
                    guard streamShouldContinue(generation) else { return }
                    let now = Date()
                    if now.timeIntervalSince(lastHealthPublication) >= 1 {
                        markStreamHealthy(.logs)
                        lastHealthPublication = now
                    }
                    attempt = 0
                    appendCoreLog(
                        CoreLogLine(
                            stream: .standardOutput,
                            message: "[\(entry.type)] \(entry.payload)"
                        )
                    )
                }
                guard streamShouldContinue(generation) else { return }
                throw AppModelError.streamEnded("Log")
            } catch is CancellationError {
                return
            } catch {
                guard streamShouldContinue(generation) else { return }
                markStreamDegraded(.logs, error: error, attempt: attempt + 1)
                appendSupervisorLog("Log stream interrupted: \(error.localizedDescription)")
                attempt += 1
                if !(await waitBeforeStreamRetry(attempt, generation: generation)) { return }
            }
        }
    }

    private func streamShouldContinue(_ generation: Int) -> Bool {
        !Task.isCancelled && generation == controllerGeneration && isConnected
    }

    private func markStreamHealthy(_ stream: LiveStream) {
        degradedStreams.remove(stream)
        var health = liveStreamHealth[stream] ?? .inactive
        health.received()
        liveStreamHealth[stream] = health
    }

    private func markStreamDegraded(
        _ stream: LiveStream,
        error: Error,
        attempt: Int
    ) {
        degradedStreams.insert(stream)
        var health = liveStreamHealth[stream] ?? .inactive
        health.failed(error, attempt: attempt)
        liveStreamHealth[stream] = health
    }

    private func nextProxyRefreshRevision() -> Int {
        proxyRefreshRevision &+= 1
        return proxyRefreshRevision
    }

    private func invalidateProxyRefreshes() {
        proxyRefreshRevision &+= 1
    }

    private func waitBeforeStreamRetry(_ attempt: Int, generation: Int) async -> Bool {
        let seconds = min(1 << min(max(attempt - 1, 0), 3), 8)
        do {
            try await Task.sleep(for: .seconds(seconds))
            return streamShouldContinue(generation)
        } catch {
            return false
        }
    }

    private func stopControllerStreams() {
        supervisor.setProcessLogForwardingEnabled(false)
        controllerSetupOperation?.task.cancel()
        controllerSetupOperation = nil
        cancelControllerStreamTasks()
        controllerGeneration &+= 1
        invalidateProxyRefreshes()
        apiClient = nil
        activeControllerEndpoint = nil
        controllerState = .idle
        runtimeConfig = nil
        managedMixedPort = nil
        proxyGroups = []
        proxiesByName = [:]
        proxyTopology = .empty
        proxyTopologyInput = nil
        proxySelectionPaths = [:]
        proxyDelays = [:]
        contextualProxyDelays = [:]
        proxyProfileStructure = .empty
        if let activeProfileID {
            invalidateProfileProxyWorkspace(
                activeProfileID,
                state: .unavailable(.primaryControllerNotReady)
            )
        }
        rules = []
        rulesLastLoadedAt = nil
        proxyProviders = []
        ruleProviders = []
        providersLastLoadedAt = nil
        providerOperationReceipts = [:]
        rulesErrorMessage = nil
        providersErrorMessage = nil
        degradedStreams = []
        for stream in LiveStream.allCases {
            liveStreamHealth[stream] = .inactive
        }
        connections = nil
        trafficAttribution.reset()
        routeTrafficEntries = []
        traffic = MihomoTraffic(upload: 0, download: 0, uploadTotal: 0, downloadTotal: 0)
        trafficHistory = []
    }

    private func startNetworkEnvironmentMonitoring() {
        guard prepared, !shutdownInProgress, networkEnvironmentEventTask == nil else { return }
        invalidateNetworkExtensionPreferencesChecks()
        let events = networkEnvironmentMonitor.start()
        networkEnvironmentEventTask = Task { @MainActor [weak self] in
            for await event in events {
                guard !Task.isCancelled, let self else { return }
                self.receiveNetworkEnvironmentEvent(event)
            }
        }
    }

    private func stopNetworkEnvironmentMonitoring() {
        networkEnvironmentEventTask?.cancel()
        networkEnvironmentEventTask = nil
        networkEnvironmentDebounceGeneration &+= 1
        networkEnvironmentDebounceTask?.cancel()
        networkEnvironmentDebounceTask = nil
        invalidateNetworkEnvironmentRecovery()
        networkEnvironmentMonitor.stop()
        networkEnvironmentRecoveryArmed = false
        networkEnvironmentRecoveryPolicy = NetworkEnvironmentRecoveryPolicy()
        networkEnvironmentPathIsUsable = nil
        appRoutingMonitorsPausedForSleep = false
    }

    private func resumeNetworkEnvironmentMonitoringAfterCancelledShutdown(
        recoveryWasArmed: Bool
    ) {
        guard prepared, !shutdownInProgress else { return }
        setNetworkEnvironmentRecoveryArmed(recoveryWasArmed)
        startNetworkEnvironmentMonitoring()
    }

    private func setNetworkEnvironmentRecoveryArmed(_ armed: Bool) {
        if !armed, networkEnvironmentRecoveryArmed {
            invalidateNetworkEnvironmentRecovery()
        }
        networkEnvironmentRecoveryArmed = armed
        applyNetworkEnvironmentRecoveryDirective(
            networkEnvironmentRecoveryPolicy.setArmed(armed)
        )
    }

    private func receiveNetworkEnvironmentEvent(_ event: NetworkEnvironmentEvent) {
        guard !shutdownInProgress else { return }
        if event == .networkExtensionConfigurationChanged {
            invalidateNetworkExtensionPreferencesChecks()
            return
        }
        if event == .willSleep {
            pauseAppRoutingMonitorsForSleep()
            invalidateNetworkEnvironmentRecovery()
        } else if case let .pathChanged(path) = event {
            networkEnvironmentPathIsUsable = path.isUsable
            if !path.isUsable {
                invalidateNetworkEnvironmentRecovery()
            }
        }
        applyNetworkEnvironmentRecoveryDirective(
            networkEnvironmentRecoveryPolicy.receive(event)
        )
    }

    private func invalidateNetworkExtensionPreferencesChecks() {
        networkExtensionPreferencesCheckGeneration &+= 1
        appRoutingProviderPreferencesCheckDeadline = nil
        dnsProxyPreferencesCheckDeadline = nil
    }

    private func networkExtensionPreferencesCheckIsDue(
        _ deadline: ContinuousClock.Instant?
    ) -> Bool {
        guard let deadline else { return true }
        return deadline <= ContinuousClock.now
    }

    private func pauseAppRoutingMonitorsForSleep() {
        appRoutingMonitorsPausedForSleep = true
        guard appRoutingActivityTask != nil || dnsProxyRuntimeTask != nil else {
            return
        }
        appRoutingActivityTask?.cancel()
        appRoutingActivityTask = nil
        appRoutingActivityMonitorMode = nil
        appRoutingMonitorGeneration &+= 1
        dnsProxyRuntimeTask?.cancel()
        dnsProxyRuntimeTask = nil
        dnsProxyMonitorGeneration &+= 1
    }

    private func resumeAppRoutingMonitorsAfterSleepIfNeeded() {
        guard appRoutingMonitorsPausedForSleep else { return }
        guard !networkEnvironmentRecoveryPolicy.isSleeping else { return }
        guard !shutdownInProgress,
              networkCapturePreferences.enabled,
              case .on = networkCaptureState else {
            appRoutingMonitorsPausedForSleep = false
            return
        }
        guard networkEnvironmentPathIsUsable != false else { return }
        guard networkEnvironmentDebounceTask == nil,
              networkEnvironmentRecoveryTask == nil else { return }
        appRoutingMonitorsPausedForSleep = false
        appRoutingProviderStatusFailureCount = 0
        appRoutingProviderLastVerifiedAt = nil
        startDNSProxyRuntimeMonitor()
        launchAppRoutingActivityMonitor(forceRestart: true)
    }

    private func applyNetworkEnvironmentRecoveryDirective(
        _ directive: NetworkEnvironmentRecoveryPolicy.Directive
    ) {
        switch directive {
        case .none:
            resumeAppRoutingMonitorsAfterSleepIfNeeded()
            return

        case .cancelScheduledRecovery:
            networkEnvironmentDebounceGeneration &+= 1
            networkEnvironmentDebounceTask?.cancel()
            networkEnvironmentDebounceTask = nil

        case let .schedule(delay):
            networkEnvironmentDebounceGeneration &+= 1
            let generation = networkEnvironmentDebounceGeneration
            networkEnvironmentDebounceTask?.cancel()
            networkEnvironmentDebounceTask = Task { @MainActor [weak self] in
                do {
                    try await Task.sleep(for: .seconds(delay))
                } catch {
                    return
                }
                guard let self,
                      !Task.isCancelled,
                      generation == self.networkEnvironmentDebounceGeneration else { return }
                self.networkEnvironmentDebounceTask = nil
                self.applyNetworkEnvironmentRecoveryDirective(
                    self.networkEnvironmentRecoveryPolicy.scheduledRecoveryFired()
                )
            }

        case .recover:
            networkEnvironmentRecoveryGeneration &+= 1
            let generation = networkEnvironmentRecoveryGeneration
            networkEnvironmentRecoveryTask?.cancel()
            networkEnvironmentRecoveryTask = Task { @MainActor [weak self] in
                guard let self else { return }
                let result = await self.performNetworkEnvironmentRecovery(
                    generation: generation
                )
                guard !Task.isCancelled,
                      generation == self.networkEnvironmentRecoveryGeneration else { return }
                guard let succeeded = result else {
                    self.networkEnvironmentRecoveryTask = nil
                    self.applyNetworkEnvironmentRecoveryDirective(
                        self.networkEnvironmentRecoveryPolicy.recoveryDeferred()
                    )
                    self.resumeAppRoutingMonitorsAfterSleepIfNeeded()
                    return
                }
                self.networkEnvironmentRecoveryTask = nil
                self.applyNetworkEnvironmentRecoveryDirective(
                    self.networkEnvironmentRecoveryPolicy.recoveryCompleted(
                        succeeded: succeeded
                    )
                )
                self.resumeAppRoutingMonitorsAfterSleepIfNeeded()
            }

        case .suppressAfterRepeatedFailures:
            appendSupervisorLog(
                "Automatic network-environment recovery paused after repeated failures. A later wake or network-path change will re-evaluate the session."
            )
            resumeAppRoutingMonitorsAfterSleepIfNeeded()
        }
    }

    private func invalidateNetworkEnvironmentRecovery() {
        networkEnvironmentRecoveryGeneration &+= 1
        networkEnvironmentRecoveryTask?.cancel()
        networkEnvironmentRecoveryTask = nil
    }

    private func performNetworkEnvironmentRecovery(generation: UInt64) async -> Bool? {
        guard networkEnvironmentRecoveryCanContinue(generation: generation) else {
            return nil
        }
        guard !operations.contains(.recoverNetworkEnvironment) else { return nil }
        guard begin(.recoverNetworkEnvironment) else {
            appendSupervisorLog(
                "Network-environment recovery was deferred while another network operation was in progress."
            )
            return nil
        }
        defer { end(.recoverNetworkEnvironment) }

        appendSupervisorLog(
            "Verifying the network data plane after a wake or network-path change."
        )

        if !(await verifyCoreAndLocalListenersForNetworkRecovery(generation: generation)) {
            guard networkEnvironmentRecoveryCanContinue(generation: generation) else {
                return false
            }
            guard await reconnectForNetworkEnvironmentRecovery(generation: generation) else {
                return false
            }
        }
        guard networkEnvironmentRecoveryCanContinue(generation: generation),
              isConnected,
              controllerIsReady else { return false }

        guard await verifyOrRecoverAppRoutingForNetworkEnvironment(
            generation: generation
        ) else {
            return false
        }
        guard networkEnvironmentRecoveryCanContinue(generation: generation),
              await verifySystemProxyForNetworkEnvironment(generation: generation) else {
            return false
        }

        appendSupervisorLog("Network-environment recovery verification succeeded.")
        return true
    }

    private func networkEnvironmentRecoveryCanContinue(generation: UInt64) -> Bool {
        generation == networkEnvironmentRecoveryGeneration
            && networkEnvironmentRecoveryArmed
            && networkEnvironmentPathIsUsable != false
            && !networkEnvironmentRecoveryPolicy.isSleeping
            && !shutdownInProgress
            && !Task.isCancelled
    }

    private func verifyCoreAndLocalListenersForNetworkRecovery(
        generation: UInt64
    ) async -> Bool {
        guard networkEnvironmentRecoveryCanContinue(generation: generation) else {
            return false
        }
        guard isConnected,
              controllerIsReady,
              let session = runningSession,
              let httpPort = localHTTPProxyPort,
              let socksPort = localSOCKSProxyPort else { return false }
        do {
            let probe = try MihomoAPIClient(
                baseURL: session.endpoint,
                secret: session.secret,
                requestTimeout: 3
            )
            _ = try await probe.fetchVersion()
            guard networkEnvironmentRecoveryCanContinue(generation: generation) else {
                return false
            }
            try Task.checkCancellation()
            try await localPortProbe.waitUntilProxyProtocols(
                httpPort: httpPort,
                socksPort: socksPort
            )
            guard networkEnvironmentRecoveryCanContinue(generation: generation) else {
                return false
            }
            if let dedicatedPort = activeProfileDedicatedMixedListener.map({
                Int($0.port)
            }) {
                try await localPortProbe.waitUntilProxyProtocols(
                    httpPort: dedicatedPort,
                    socksPort: dedicatedPort
                )
                guard networkEnvironmentRecoveryCanContinue(generation: generation) else {
                    return false
                }
            }
            if let activeProfileID {
                try await verifyProfileRouteListenerProtocols(
                    profileID: activeProfileID
                )
                guard networkEnvironmentRecoveryCanContinue(generation: generation) else {
                    return false
                }
            }
            if activeNetworkExtensionMihomoListener != nil {
                try await localPortProbe.waitUntilListening(
                    ports: Set(try activeNetworkExtensionRouteProxyEndpoints().map {
                        Int($0.port)
                    })
                )
                guard networkEnvironmentRecoveryCanContinue(generation: generation) else {
                    return false
                }
            }
            return true
        } catch is CancellationError {
            return false
        } catch {
            appendSupervisorLog(
                "Core or local listener verification failed after the network environment changed: \(error.localizedDescription)"
            )
            return false
        }
    }

    private func reconnectForNetworkEnvironmentRecovery(generation: UInt64) async -> Bool {
        guard networkEnvironmentRecoveryCanContinue(generation: generation) else { return false }
        let shouldRestoreSystemProxy = systemProxyEnabled || hasSystemProxySnapshot
        appendSupervisorLog(
            "Restarting the current proxy session because the core, controller, or a local listener could not be verified."
        )
        guard await performDisconnect(),
              networkEnvironmentRecoveryCanContinue(generation: generation) else { return false }
        guard await performConnect() else { return false }
        guard networkEnvironmentRecoveryCanContinue(generation: generation) else { return false }
        if shouldRestoreSystemProxy, !networkCapturePreferences.enabled {
            await enableSystemProxyAfterConnect()
        }
        guard networkEnvironmentRecoveryCanContinue(generation: generation) else { return false }
        return await verifyCoreAndLocalListenersForNetworkRecovery(generation: generation)
    }

    private func verifyOrRecoverAppRoutingForNetworkEnvironment(
        generation: UInt64
    ) async -> Bool {
        guard networkEnvironmentRecoveryCanContinue(generation: generation) else { return false }
        guard networkCapturePreferences.enabled else { return true }
        switch networkCaptureState {
        case .requiresReboot, .awaitingUserApproval:
            // These require explicit operating-system or user action; repeatedly
            // restarting the data plane cannot make progress.
            return true
        case .enabling, .disabling:
            return false
        case .off, .waitingForConnection, .failed:
            return await restartAppRoutingForNetworkEnvironment(generation: generation)
        case let .on(revision):
            guard await appRoutingRuntimeIsHealthyForNetworkEnvironment(
                expectedRevision: revision,
                generation: generation
            ) else {
                return await restartAppRoutingForNetworkEnvironment(generation: generation)
            }
            return networkEnvironmentRecoveryCanContinue(generation: generation)
        }
    }

    private func appRoutingRuntimeIsHealthyForNetworkEnvironment(
        expectedRevision: UInt64,
        generation: UInt64
    ) async -> Bool {
        guard networkEnvironmentRecoveryCanContinue(generation: generation) else {
            return false
        }
        do {
            let provider = try await networkExtensionControl.providerRuntimeStatus()
            guard networkEnvironmentRecoveryCanContinue(generation: generation) else {
                return false
            }
            guard provider.running,
                  provider.captureEnabled,
                  provider.revision == expectedRevision else { return false }
            if networkCapturePreferences.dnsEnabled {
                guard let dns = try await networkExtensionControl
                    .dnsProviderRuntimeStatus(),
                    dns.isOperational else { return false }
                guard networkEnvironmentRecoveryCanContinue(generation: generation) else {
                    return false
                }
                dnsProxyRuntimeStatus = dns
                dnsProxyRuntimeError = nil
                dnsProxyRuntimeFailureCount = 0
                dnsProxyLastVerifiedAt = Date()
            }
            appRoutingProviderStatusFailureCount = 0
            appRoutingProviderLastVerifiedAt = Date()
            return true
        } catch {
            guard networkEnvironmentRecoveryCanContinue(generation: generation) else {
                return false
            }
            appendSupervisorLog(
                "App Routing runtime verification failed after the network environment changed: \(error.localizedDescription)"
            )
            return false
        }
    }

    private func restartAppRoutingForNetworkEnvironment(generation: UInt64) async -> Bool {
        guard networkEnvironmentRecoveryCanContinue(generation: generation) else { return false }
        appendSupervisorLog(
            "Retrying App Routing and DNS Routing after runtime verification failed."
        )
        if networkCaptureIsActive,
           !(await performNetworkCaptureDeactivation()) {
            return false
        }
        guard networkEnvironmentRecoveryCanContinue(generation: generation) else { return false }
        await performNetworkCaptureActivation()
        guard networkEnvironmentRecoveryCanContinue(generation: generation) else { return false }
        guard case let .on(revision) = networkCaptureState else { return false }
        return await appRoutingRuntimeIsHealthyForNetworkEnvironment(
            expectedRevision: revision,
            generation: generation
        )
    }

    private func verifySystemProxyForNetworkEnvironment(generation: UInt64) async -> Bool {
        guard networkEnvironmentRecoveryCanContinue(generation: generation) else { return false }
        guard systemProxyEnabled else { return true }
        guard let endpoints = currentSystemProxyEndpoints() else { return false }
        await performSystemProxyGuardCheck(
            endpoints: endpoints,
            bypassDomains: systemProxyPreferences.effectiveBypassDomains,
            recoveryGeneration: generation
        )
        return networkEnvironmentRecoveryCanContinue(generation: generation)
            && systemProxyGuardFailure == nil
    }

    private func startAppRoutingActivityMonitor() {
        guard !appRoutingMonitorsPausedForSleep else { return }
        appRoutingActivityTask?.cancel()
        appRoutingActivityCursor = 0
        appRoutingActivityAcknowledgedDroppedBefore = 0
        appRoutingTrafficRateTracker.reset()
        appRoutingTrafficRates = .zero
        appRoutingActiveCount = 0
        appRoutingActivityDroppedCount = 0
        appRoutingActivityCoverageStartedAt = Date()
        appRoutingProviderStatusFailureCount = 0
        appRoutingProviderLastVerifiedAt = nil
        appRoutingActivities.removeAll(keepingCapacity: true)
        appRoutingActivitiesByIdentifier.removeAll(keepingCapacity: true)
        appRoutingRuleStatistics.removeAll(keepingCapacity: true)
        appRoutingActivityError = nil
        if presentationTelemetryPolicy.appRoutingActivity {
            scheduleFlowLedgerRefresh()
        }
        degradedStreams.remove(.appRouting)
        liveStreamHealth[.appRouting] = .connecting(
            previousSampleAt: liveStreamHealth[.appRouting]?.lastReceivedAt
        )
        startDNSProxyRuntimeMonitor()
        launchAppRoutingActivityMonitor(forceRestart: true)
    }

    private func launchAppRoutingActivityMonitor(forceRestart: Bool = false) {
        guard !appRoutingMonitorsPausedForSleep else { return }
        let hasDetailedPresentation = presentationTelemetryPolicy.appRoutingActivity
        let mode: AppRoutingActivityMonitorMode = if lightweightMode
            && !hasDetailedPresentation {
            .providerOnly
        } else if hasDetailedPresentation {
            .detailed
        } else {
            .background
        }
        let providerHeartbeatHandledByDNS = mode == .providerOnly
            && networkCapturePreferences.dnsEnabled
        guard forceRestart
                || appRoutingActivityMonitorMode != mode
                || (appRoutingActivityTask == nil && !providerHeartbeatHandledByDNS)
        else { return }

        appRoutingActivityTask?.cancel()
        appRoutingActivityMonitorMode = mode
        appRoutingMonitorGeneration &+= 1
        guard !providerHeartbeatHandledByDNS else {
            appRoutingActivityTask = nil
            return
        }
        let generation = appRoutingMonitorGeneration
        appRoutingActivityTask = Task { @MainActor [weak self] in
            await self?.monitorAppRoutingActivity(generation: generation)
        }
    }

    private func monitorAppRoutingActivity(generation: UInt64) async {
        var failureAttempt = 0
        var successfulPollsSinceProviderCheck = 0
        while appRoutingMonitorShouldContinue(generation: generation) {
            guard case let .on(expectedRevision) = networkCaptureState else { return }
            let hasDetailedPresentation = presentationTelemetryPolicy.appRoutingActivity

            do {
                if lightweightMode && !hasDetailedPresentation {
                    guard !networkCapturePreferences.dnsEnabled else { return }
                    failureAttempt = 0
                    successfulPollsSinceProviderCheck = 0
                    let checkPersistedConfiguration =
                        networkExtensionPreferencesCheckIsDue(
                            appRoutingProviderPreferencesCheckDeadline
                        )
                    _ = await verifyAppRoutingProviderRuntime(
                        expectedRevision: expectedRevision,
                        requireActiveCaptureState: true,
                        monitorGeneration: generation,
                        checkPersistedConfiguration: checkPersistedConfiguration
                    )
                    guard appRoutingMonitorShouldContinue(
                        generation: generation,
                        expectedRevision: expectedRevision
                    ) else { return }
                    try await Task.sleep(for: .seconds(10))
                    continue
                }
                let initialCursor = appRoutingActivityCursor
                let initialAcknowledgedDroppedBefore =
                    appRoutingActivityAcknowledgedDroppedBefore
                var pollingCursor = AppRoutingActivityPollCursor(
                    cursor: initialCursor,
                    acknowledgedDroppedBefore: initialAcknowledgedDroppedBefore
                )
                var hasMore = true
                var activityUpdates: [AppRoutingActivity] = []
                while hasMore,
                      appRoutingMonitorShouldContinue(
                        generation: generation,
                        expectedRevision: expectedRevision
                      ), pollingCursor.consumePage() {
                    let batch = try await networkExtensionControl.appRoutingActivity(
                        after: pollingCursor.current,
                        limit: 250
                    )
                    guard appRoutingMonitorShouldContinue(
                        generation: generation,
                        expectedRevision: expectedRevision
                    ) else { return }
                    if pollingCursor.observe(
                        droppedBefore: batch.droppedBeforeSequence
                    ) {
                        activityUpdates.removeAll(keepingCapacity: true)
                        continue
                    }
                    activityUpdates.append(contentsOf: batch.activities)
                    pollingCursor.advance(to: batch.nextCursor)
                    hasMore = batch.hasMore
                    if hasMore {
                        await Task.yield()
                    }
                }
                let processingCursor = pollingCursor.committed
                let processingRevision = appRoutingActivityStateRevision
                let currentActivities = pollingCursor.requiresStateReset
                    ? []
                    : appRoutingActivities
                let currentActivitiesByIdentifier = pollingCursor.requiresStateReset
                    ? [:]
                    : appRoutingActivitiesByIdentifier
                let currentRuleStatistics = pollingCursor.requiresStateReset
                    ? [:]
                    : appRoutingRuleStatistics
                let currentRateTracker = pollingCursor.requiresStateReset
                    ? AppRoutingTrafficRateTracker()
                    : appRoutingTrafficRateTracker
                let defaultProfileID = activeProfileID
                let sampledAt = Date()
                let worker = Task.detached(priority: .utility) {
                    Self.processAppRoutingActivities(
                        updates: activityUpdates,
                        currentActivities: currentActivities,
                        currentActivitiesByIdentifier: currentActivitiesByIdentifier,
                        currentRuleStatistics: currentRuleStatistics,
                        currentRateTracker: currentRateTracker,
                        defaultProfileID: defaultProfileID,
                        sampledAt: sampledAt
                    )
                }
                let processed = await withTaskCancellationHandler {
                    await worker.value
                } onCancel: {
                    worker.cancel()
                }
                guard appRoutingMonitorShouldContinue(
                    generation: generation,
                    expectedRevision: expectedRevision
                ), appRoutingActivityCursor == initialCursor,
                   appRoutingActivityAcknowledgedDroppedBefore
                        == initialAcknowledgedDroppedBefore,
                   appRoutingActivityStateRevision == processingRevision else { continue }

                appRoutingActivityCursor = processingCursor
                appRoutingActivityAcknowledgedDroppedBefore = 0
                if pollingCursor.requiresStateReset {
                    appRoutingActivityDroppedCount = Self.saturatingAdd(
                        appRoutingActivityDroppedCount,
                        pollingCursor.droppedDelta
                    )
                    appRoutingActivityCoverageStartedAt = sampledAt
                }
                appRoutingTrafficRateTracker = processed.rateTracker
                appRoutingTrafficRates = processed.trafficRates
                appRoutingActiveCount = processed.activeCount
                if processed.mergedUpdates || pollingCursor.requiresStateReset {
                    appRoutingActivities = processed.activities
                    appRoutingActivitiesByIdentifier = processed.activitiesByIdentifier
                    appRoutingRuleStatistics = processed.ruleStatistics
                    if processed.removedCount > 0 {
                        appRoutingActivityDroppedCount = Self.saturatingAdd(
                            appRoutingActivityDroppedCount,
                            UInt64(processed.removedCount)
                        )
                    }
                    scheduleFlowLedgerRefresh(
                        neededForAccounting: pollingCursor.requiresStateReset
                            || processed.needsAccounting
                    )
                }
                failureAttempt = 0
                successfulPollsSinceProviderCheck += 1
                let providerCheckInterval = hasDetailedPresentation
                    ? Self.appRoutingProviderStatusCheckInterval
                    : 2
                if successfulPollsSinceProviderCheck
                    >= providerCheckInterval
                {
                    successfulPollsSinceProviderCheck = 0
                    _ = await verifyAppRoutingProviderRuntime(
                        expectedRevision: expectedRevision,
                        requireActiveCaptureState: true,
                        monitorGeneration: generation
                    )
                    guard appRoutingMonitorShouldContinue(
                        generation: generation,
                        expectedRevision: expectedRevision
                    ) else { return }
                } else if appRoutingProviderStatusFailureCount == 0 {
                    appRoutingActivityError = nil
                    markStreamHealthy(.appRouting)
                }
                try await Task.sleep(
                    for: hasDetailedPresentation ? .seconds(1) : .seconds(5)
                )
            } catch is CancellationError {
                return
            } catch {
                guard appRoutingMonitorShouldContinue(
                    generation: generation,
                    expectedRevision: expectedRevision
                ) else { return }
                failureAttempt += 1
                appRoutingActivityError = error.localizedDescription
                markStreamDegraded(
                    .appRouting,
                    error: error,
                    attempt: failureAttempt
                )
                if failureAttempt >= Self.appRoutingProviderFailureThreshold {
                    let message = AppLocalization.format(
                        "MClash lost contact with the App Routing provider after %@ consecutive activity checks. Traffic capture can no longer be verified. Last error: %@",
                        String(failureAttempt),
                        error.localizedDescription
                    )
                    networkCaptureState = .failed(message)
                    appendSupervisorLog(message)
                    return
                }
                do {
                    try await Task.sleep(for: .seconds(2))
                } catch {
                    return
                }
            }
        }
    }

    private func appRoutingMonitorShouldContinue(
        generation: UInt64,
        expectedRevision: UInt64? = nil
    ) -> Bool {
        guard !Task.isCancelled,
              !appRoutingMonitorsPausedForSleep,
              generation == appRoutingMonitorGeneration else { return false }
        guard let expectedRevision else { return true }
        return networkCaptureState.isActive(revision: expectedRevision)
    }

    private func startDNSProxyRuntimeMonitor() {
        guard !appRoutingMonitorsPausedForSleep else { return }
        dnsProxyRuntimeTask?.cancel()
        dnsProxyMonitorGeneration &+= 1
        invalidateNetworkExtensionPreferencesChecks()
        let generation = dnsProxyMonitorGeneration
        dnsProxyRuntimeFailureCount = 0
        dnsProxyRuntimeStatus = nil
        dnsProxyLastVerifiedAt = nil
        guard networkCapturePreferences.dnsEnabled else {
            dnsProxyRuntimeError = nil
            return
        }
        dnsProxyRuntimeTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while self.dnsProxyMonitorShouldContinue(generation: generation) {
                guard case let .on(expectedRevision) = networkCaptureState else { return }
                let checkDNSPersistedConfiguration = !lightweightMode
                    || presentationTelemetryPolicy.appRoutingActivity
                    || networkExtensionPreferencesCheckIsDue(
                        dnsProxyPreferencesCheckDeadline
                    )
                if appRoutingActivityMonitorMode == .providerOnly {
                    let appMonitorGeneration = appRoutingMonitorGeneration
                    await refreshProviderAndDNSRuntime(
                        expectedRevision: expectedRevision,
                        appMonitorGeneration: appMonitorGeneration,
                        dnsMonitorGeneration: generation,
                        checkProviderPersistedConfiguration:
                            networkExtensionPreferencesCheckIsDue(
                                appRoutingProviderPreferencesCheckDeadline
                            ),
                        checkDNSPersistedConfiguration: checkDNSPersistedConfiguration
                    )
                } else {
                    await refreshDNSProxyRuntime(
                        expectedRevision: expectedRevision,
                        monitorGeneration: generation,
                        checkPersistedConfiguration: checkDNSPersistedConfiguration
                    )
                }
                do {
                    try await Task.sleep(
                        for: presentationTelemetryPolicy
                            .dnsProxyRuntimePollInterval(lightweightMode: lightweightMode)
                    )
                } catch {
                    return
                }
            }
        }
    }

    private func refreshDNSProxyRuntime(
        expectedRevision: UInt64,
        monitorGeneration: UInt64,
        checkPersistedConfiguration: Bool
    ) async {
        guard networkCapturePreferences.dnsEnabled,
              !dnsProxyAutomaticallyDisabled,
              dnsProxyMonitorShouldContinue(
                generation: monitorGeneration,
                expectedRevision: expectedRevision
              ) else { return }
        let preferencesCheckGeneration = networkExtensionPreferencesCheckGeneration
        if checkPersistedConfiguration {
            dnsProxyPreferencesCheckDeadline = nil
        }
        let result: Result<
            DNSProxyRuntimeStatus?,
            NetworkExtensionRuntimeObservationError
        >
        do {
            let currentStatus = if checkPersistedConfiguration {
                try await networkExtensionControl.dnsProviderRuntimeStatus()
            } else {
                try await networkExtensionControl.dnsProviderRuntimeHeartbeat()
            }
            result = .success(currentStatus)
        } catch {
            result = .failure(NetworkExtensionRuntimeObservationError(error))
        }
        guard dnsProxyMonitorShouldContinue(
            generation: monitorGeneration,
            expectedRevision: expectedRevision
        ) else { return }
        guard let runtimeFailure = recordDNSProxyRuntimeResult(
            result,
            checkPersistedConfiguration: checkPersistedConfiguration,
            preferencesCheckGeneration: preferencesCheckGeneration
        ) else { return }
        await stopUnverifiedDNSProxyRuntime(
            runtimeFailure,
            expectedRevision: expectedRevision,
            dnsMonitorGeneration: monitorGeneration
        )
    }

    private func refreshProviderAndDNSRuntime(
        expectedRevision: UInt64,
        appMonitorGeneration: UInt64,
        dnsMonitorGeneration: UInt64,
        checkProviderPersistedConfiguration: Bool,
        checkDNSPersistedConfiguration: Bool
    ) async {
        guard networkCapturePreferences.dnsEnabled,
              !dnsProxyAutomaticallyDisabled,
              runtimeMonitorsShouldContinue(
                appGeneration: appMonitorGeneration,
                dnsGeneration: dnsMonitorGeneration,
                expectedRevision: expectedRevision
        ) else { return }
        let preferencesCheckGeneration = networkExtensionPreferencesCheckGeneration
        if checkDNSPersistedConfiguration {
            dnsProxyPreferencesCheckDeadline = nil
        }
        let observation = await networkExtensionControl
            .providerAndDNSRuntimeObservation(
                checkDNSPersistedConfiguration: checkDNSPersistedConfiguration
            )
        guard runtimeMonitorsShouldContinue(
            appGeneration: appMonitorGeneration,
            dnsGeneration: dnsMonitorGeneration,
            expectedRevision: expectedRevision
        ) else { return }

        let dnsFailure = recordDNSProxyRuntimeResult(
            observation.dnsStatus,
            checkPersistedConfiguration: checkDNSPersistedConfiguration,
            preferencesCheckGeneration: preferencesCheckGeneration
        )
        let providerResult: (verified: Bool, failureMessage: String?)?
        if case .failure = observation.providerStatus {
            providerResult = recordAppRoutingProviderRuntimeResult(
                observation.providerStatus,
                expectedRevision: expectedRevision,
                checkPersistedConfiguration: false,
                preferencesCheckGeneration: preferencesCheckGeneration
            )
        } else if checkProviderPersistedConfiguration
                    || appRoutingActivityTask != nil {
            // A due or in-flight full check owns the Provider failure counter.
            // Healthy snapshots must not erase its consecutive failures.
            providerResult = nil
        } else {
            providerResult = recordAppRoutingProviderRuntimeResult(
                observation.providerStatus,
                expectedRevision: expectedRevision,
                checkPersistedConfiguration: false,
                preferencesCheckGeneration: preferencesCheckGeneration
            )
        }

        if let dnsFailure {
            await stopUnverifiedDNSProxyRuntime(
                dnsFailure,
                expectedRevision: expectedRevision,
                dnsMonitorGeneration: dnsMonitorGeneration
            )
            return
        }
        if let failureMessage = providerResult?.failureMessage {
            networkCaptureState = .failed(failureMessage)
            appendSupervisorLog(failureMessage)
            return
        }
        if checkProviderPersistedConfiguration,
           case .success = observation.providerStatus {
            launchAppRoutingProviderPreferencesCheck(
                expectedRevision: expectedRevision,
                appMonitorGeneration: appMonitorGeneration,
                dnsMonitorGeneration: dnsMonitorGeneration
            )
        }
    }

    private func launchAppRoutingProviderPreferencesCheck(
        expectedRevision: UInt64,
        appMonitorGeneration: UInt64,
        dnsMonitorGeneration: UInt64
    ) {
        guard appRoutingActivityTask == nil,
              appRoutingActivityMonitorMode == .providerOnly,
              runtimeMonitorsShouldContinue(
                appGeneration: appMonitorGeneration,
                dnsGeneration: dnsMonitorGeneration,
                expectedRevision: expectedRevision
              ) else { return }
        let preferencesCheckGeneration = networkExtensionPreferencesCheckGeneration
        appRoutingProviderPreferencesCheckDeadline = nil
        appRoutingActivityTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if appMonitorGeneration == self.appRoutingMonitorGeneration,
                   self.appRoutingActivityMonitorMode == .providerOnly {
                    self.appRoutingActivityTask = nil
                }
            }
            guard self.runtimeMonitorsShouldContinue(
                appGeneration: appMonitorGeneration,
                dnsGeneration: dnsMonitorGeneration,
                expectedRevision: expectedRevision
            ) else { return }
            let result: Result<
                TransparentProxyProviderStatus,
                NetworkExtensionRuntimeObservationError
            >
            do {
                result = .success(
                    try await self.networkExtensionControl.providerRuntimeStatus()
                )
            } catch {
                result = .failure(NetworkExtensionRuntimeObservationError(error))
            }
            guard self.runtimeMonitorsShouldContinue(
                appGeneration: appMonitorGeneration,
                dnsGeneration: dnsMonitorGeneration,
                expectedRevision: expectedRevision
            ) else { return }
            let recorded = self.recordAppRoutingProviderRuntimeResult(
                result,
                expectedRevision: expectedRevision,
                checkPersistedConfiguration: true,
                preferencesCheckGeneration: preferencesCheckGeneration
            )
            if let failureMessage = recorded.failureMessage {
                self.networkCaptureState = .failed(failureMessage)
                self.appendSupervisorLog(failureMessage)
            }
        }
    }

    private func recordDNSProxyRuntimeResult(
        _ result: Result<
            DNSProxyRuntimeStatus?,
            NetworkExtensionRuntimeObservationError
        >,
        checkPersistedConfiguration: Bool,
        preferencesCheckGeneration: UInt64
    ) -> NetworkExtensionRuntimeObservationError? {
        do {
            guard let status = try result.get() else {
                throw NSError(
                    domain: "one.leaper.mclash.dns-runtime",
                    code: 0,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            AppLocalization.string(
                                "DNS Provider runtime status is unavailable"
                            )
                    ]
                )
            }
            guard status.isOperational else {
                throw NSError(
                    domain: "one.leaper.mclash.dns-runtime",
                    code: 1,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            AppLocalization.format(
                                "DNS Provider revision %@ is %@ and backendReady=%@",
                                String(status.revision),
                                status.phase.rawValue,
                                String(status.backendReady)
                            )
                    ]
                )
            }
            if checkPersistedConfiguration,
               preferencesCheckGeneration == networkExtensionPreferencesCheckGeneration {
                dnsProxyPreferencesCheckDeadline = ContinuousClock.now
                    + Self.networkExtensionPreferencesCheckInterval
            }
            dnsProxyRuntimeStatus = status
            dnsProxyRuntimeError = nil
            dnsProxyRuntimeFailureCount = 0
            dnsProxyLastVerifiedAt = Date()
            return nil
        } catch {
            let runtimeFailure = error as? NetworkExtensionRuntimeObservationError
                ?? NetworkExtensionRuntimeObservationError(error)
            dnsProxyRuntimeStatus = nil
            dnsProxyRuntimeFailureCount += 1
            dnsProxyRuntimeError = runtimeFailure.localizedDescription
            return dnsProxyRuntimeFailureCount >= 2 ? runtimeFailure : nil
        }
    }

    private func stopUnverifiedDNSProxyRuntime(
        _ runtimeFailure: NetworkExtensionRuntimeObservationError,
        expectedRevision: UInt64,
        dnsMonitorGeneration: UInt64
    ) async {
        do {
            // DNS is part of the default App Routing data plane. If its
            // persisted manager or Provider heartbeat cannot be verified,
            // stop both providers so the UI never claims a partially active
            // routing mode.
            guard dnsProxyMonitorShouldContinue(
                generation: dnsMonitorGeneration,
                expectedRevision: expectedRevision
            ) else { return }
            try await networkExtensionControl.disable()
            guard dnsProxyMonitorShouldContinue(generation: dnsMonitorGeneration) else {
                return
            }
            dnsProxyAutomaticallyDisabled = true
            let message = AppLocalization.format(
                "App Routing and DNS Routing were stopped together because the DNS Provider heartbeat or Mihomo backend could not be verified. macOS system DNS was restored. Last error: %@",
                runtimeFailure.localizedDescription
            )
            dnsProxyRuntimeError = message
            networkCaptureState = .failed(message)
            appendSupervisorLog(message)
        } catch let shutdownFailure {
            guard dnsProxyMonitorShouldContinue(
                generation: dnsMonitorGeneration,
                expectedRevision: expectedRevision
            ) else { return }
            let message = AppLocalization.format(
                "DNS Routing became unverified and MClash could not confirm that the coupled App Routing data plane shut down safely. Runtime error: %@ Shutdown error: %@",
                runtimeFailure.localizedDescription,
                shutdownFailure.localizedDescription
            )
            dnsProxyRuntimeError = message
            networkCaptureState = .failed(message)
            appendSupervisorLog(message)
        }
    }

    private func runtimeMonitorsShouldContinue(
        appGeneration: UInt64?,
        dnsGeneration: UInt64,
        expectedRevision: UInt64? = nil
    ) -> Bool {
        guard dnsProxyMonitorShouldContinue(
            generation: dnsGeneration,
            expectedRevision: expectedRevision
        ) else { return false }
        guard let appGeneration else { return true }
        return appRoutingMonitorShouldContinue(
            generation: appGeneration,
            expectedRevision: expectedRevision
        )
    }

    private func dnsProxyMonitorShouldContinue(
        generation: UInt64,
        expectedRevision: UInt64? = nil
    ) -> Bool {
        guard !Task.isCancelled,
              !appRoutingMonitorsPausedForSleep,
              generation == dnsProxyMonitorGeneration else { return false }
        guard let expectedRevision else { return true }
        return networkCaptureState.isActive(revision: expectedRevision)
    }

    /// Verifies the provider's actual runtime truth instead of trusting the
    /// host-side state left by a previous successful enable operation.
    @discardableResult
    func verifyAppRoutingProviderRuntime(
        expectedRevision: UInt64,
        requireActiveCaptureState: Bool = false,
        monitorGeneration: UInt64? = nil,
        checkPersistedConfiguration: Bool = true
    ) async -> Bool {
        if let monitorGeneration,
           !appRoutingMonitorShouldContinue(
            generation: monitorGeneration,
            expectedRevision: expectedRevision
           ) {
            return false
        }
        if requireActiveCaptureState,
           !networkCaptureState.isActive(revision: expectedRevision) {
            return false
        }
        let preferencesCheckGeneration = networkExtensionPreferencesCheckGeneration
        if checkPersistedConfiguration {
            appRoutingProviderPreferencesCheckDeadline = nil
        }
        let result: Result<
            TransparentProxyProviderStatus,
            NetworkExtensionRuntimeObservationError
        >
        do {
            let status = if checkPersistedConfiguration {
                try await networkExtensionControl.providerRuntimeStatus()
            } else {
                try await networkExtensionControl.providerRuntimeHeartbeat()
            }
            result = .success(status)
        } catch {
            result = .failure(NetworkExtensionRuntimeObservationError(error))
        }
        if let monitorGeneration,
           !appRoutingMonitorShouldContinue(
            generation: monitorGeneration,
            expectedRevision: expectedRevision
           ) {
            return false
        }
        if requireActiveCaptureState,
           !networkCaptureState.isActive(revision: expectedRevision) {
            return false
        }
        let recorded = recordAppRoutingProviderRuntimeResult(
            result,
            expectedRevision: expectedRevision,
            checkPersistedConfiguration: checkPersistedConfiguration,
            preferencesCheckGeneration: preferencesCheckGeneration
        )
        if let failureMessage = recorded.failureMessage {
            networkCaptureState = .failed(failureMessage)
            appendSupervisorLog(failureMessage)
        }
        return recorded.verified
    }

    private func recordAppRoutingProviderRuntimeResult(
        _ result: Result<
            TransparentProxyProviderStatus,
            NetworkExtensionRuntimeObservationError
        >,
        expectedRevision: UInt64,
        checkPersistedConfiguration: Bool,
        preferencesCheckGeneration: UInt64
    ) -> (verified: Bool, failureMessage: String?) {
        do {
            let status = try result.get()
            guard status.running,
                  status.captureEnabled,
                  status.revision == expectedRevision else {
                throw AppRoutingProviderRuntimeError.stateMismatch(
                    expectedRevision: expectedRevision,
                    actualRevision: status.revision,
                    running: status.running,
                    captureEnabled: status.captureEnabled,
                    providerMessage: status.message
                )
            }
            if checkPersistedConfiguration,
               preferencesCheckGeneration == networkExtensionPreferencesCheckGeneration {
                appRoutingProviderPreferencesCheckDeadline = ContinuousClock.now
                    + Self.networkExtensionPreferencesCheckInterval
            }
            appRoutingProviderStatusFailureCount = 0
            appRoutingProviderLastVerifiedAt = Date()
            appRoutingActivityError = nil
            degradedStreams.remove(.appRouting)
            return (true, nil)
        } catch {
            appRoutingProviderStatusFailureCount += 1
            let count = appRoutingProviderStatusFailureCount
            let reason = error.localizedDescription
            appRoutingActivityError = AppLocalization.format(
                "Provider verification failed: %@",
                reason
            )
            markStreamDegraded(.appRouting, error: error, attempt: count)

            if count >= Self.appRoutingProviderFailureThreshold {
                let message = AppLocalization.format(
                    "App Routing is no longer verified after %@ consecutive provider checks. Expected active revision %@. Last error: %@",
                    String(count),
                    String(expectedRevision),
                    reason
                )
                return (false, message)
            } else if count == 1 {
                appendSupervisorLog(
                    AppLocalization.format(
                        "App Routing provider verification is retrying: %@",
                        reason
                    )
                )
            }
            return (false, nil)
        }
    }

    private func stopAppRoutingActivityMonitor() {
        appRoutingActivityTask?.cancel()
        appRoutingActivityTask = nil
        appRoutingActivityMonitorMode = nil
        appRoutingActivityAcknowledgedDroppedBefore = 0
        appRoutingMonitorGeneration &+= 1
        dnsProxyRuntimeTask?.cancel()
        dnsProxyRuntimeTask = nil
        dnsProxyMonitorGeneration &+= 1
        invalidateNetworkExtensionPreferencesChecks()
        appRoutingProviderStatusFailureCount = 0
        appRoutingProviderLastVerifiedAt = nil
        degradedStreams.remove(.appRouting)
        liveStreamHealth[.appRouting] = .inactive
        appRoutingActivitiesByIdentifier.removeAll(keepingCapacity: true)
        dnsProxyRuntimeStatus = nil
        dnsProxyLastVerifiedAt = nil
        dnsProxyRuntimeFailureCount = 0
        appRoutingTrafficRateTracker.reset()
        appRoutingTrafficRates = .zero
        appRoutingActiveCount = 0
    }

    nonisolated private static func processAppRoutingActivities(
        updates: [AppRoutingActivity],
        currentActivities: [AppRoutingActivity],
        currentActivitiesByIdentifier: [UUID: AppRoutingActivity],
        currentRuleStatistics: [String: AppRoutingRuleStatistics],
        currentRateTracker: AppRoutingTrafficRateTracker,
        defaultProfileID: ProfileID?,
        sampledAt: Date
    ) -> AppRoutingActivityProcessingResult {
        var activities = currentActivities
        var activitiesByIdentifier = currentActivitiesByIdentifier
        var ruleStatistics = currentRuleStatistics
        var removedCount = 0
        var needsAccounting = false

        for activity in updates {
            activitiesByIdentifier[activity.flowIdentifier] = activity
            if activity.endedAt != nil
                || activity.relayState == .completed
                || activity.relayState == .failed
                || activity.relayState == .notApplicable {
                needsAccounting = true
            }
        }
        if !updates.isEmpty {
            activities = activitiesByIdentifier.values.sorted {
                if $0.startedAt != $1.startedAt { return $0.startedAt > $1.startedAt }
                return $0.sequence > $1.sequence
            }
            if activities.count > 2_000 {
                removedCount = activities.count - 2_000
                activities.removeLast(removedCount)
                activitiesByIdentifier = Dictionary(
                    uniqueKeysWithValues: activities.map {
                        ($0.flowIdentifier, $0)
                    }
                )
            }
            ruleStatistics = makeAppRoutingRuleStatistics(
                from: activities
            )
        }

        var rateTracker = currentRateTracker
        let trafficRates = rateTracker.ingest(
            activities,
            defaultProfileID: defaultProfileID,
            at: sampledAt
        )
        let activeCount = activities.count { $0.isLiveManagedFlow }
        return AppRoutingActivityProcessingResult(
            activities: activities,
            activitiesByIdentifier: activitiesByIdentifier,
            ruleStatistics: ruleStatistics,
            rateTracker: rateTracker,
            trafficRates: trafficRates,
            activeCount: activeCount,
            removedCount: removedCount,
            mergedUpdates: !updates.isEmpty,
            needsAccounting: needsAccounting
        )
    }

    nonisolated private static func makeAppRoutingRuleStatistics(
        from activities: [AppRoutingActivity]
    ) -> [String: AppRoutingRuleStatistics] {
        activities.reduce(into: [:]) { result, activity in
            guard let identifier = activity.matchedRuleIdentifier else { return }
            var value = result[identifier] ?? .zero
            value.matchCount += 1
            if activity.isLiveManagedFlow {
                value.activeCount += 1
            }
            if activity.relayState == .failed { value.failureCount += 1 }
            value.lastMatchedAt = max(
                value.lastMatchedAt ?? .distantPast,
                activity.startedAt
            )

            let isMeasured: Bool = switch activity.effectiveAction {
            case .mihomo: true
            case .direct: activity.payloadBytesAreMeasured == true
            case .reject: true
            case .failOpen: false
            }
            if isMeasured {
                value.measuredBytes = saturatingAdd(
                    value.measuredBytes,
                    activity.uploadBytes
                )
                value.measuredBytes = saturatingAdd(
                    value.measuredBytes,
                    activity.downloadBytes
                )
            } else {
                value.unmeasuredCount += 1
            }
            result[identifier] = value
        }
    }

    @discardableResult
    private func invalidateFlowLedgerRefresh() -> Task<Void, Never>? {
        flowLedgerRevision &+= 1
        flowLedgerTaskGeneration &+= 1
        let task = flowLedgerTask
        flowLedgerTask?.cancel()
        flowLedgerTask = nil
        flowLedgerAccountingRefreshPending = false
        flowLedgerPresentationRefreshPending = false
        flowLedgerActiveBuildNeedsAccounting = false
        return task
    }

    @discardableResult
    private func invalidateTrafficHistoryWriter() -> Task<Void, Never>? {
        trafficHistoryPersistGeneration &+= 1
        let task = trafficHistoryPersistTask ?? trafficHistoryPersistDrainTask
        trafficHistoryPersistTask?.cancel()
        trafficHistoryPersistTask = nil
        trafficHistoryPersistDrainTask = task
        trafficHistoryPersistDrainGeneration = task == nil
            ? nil
            : trafficHistoryPersistGeneration
        return task
    }

    private func shouldPruneTrafficHistory(at date: Date) -> Bool {
        guard let lastPrunedAt = trafficHistoryLastPrunedAt else { return true }
        return date.timeIntervalSince(lastPrunedAt) >= Self.trafficHistoryPruneInterval
    }

    private func scheduleFlowLedgerRefresh(neededForAccounting: Bool = false) {
        flowLedgerRevision &+= 1
        if neededForAccounting {
            flowLedgerAccountingRefreshPending = true
        } else {
            flowLedgerPresentationRefreshPending = true
        }
        startFlowLedgerRefreshIfNeeded()
    }

    private func startFlowLedgerRefreshIfNeeded() {
        let needsRefresh = flowLedgerAccountingRefreshPending
            || flowLedgerPresentationRefreshPending
        guard !trafficHistoryClearInProgress,
              !trafficHistoryPersistenceTransitionInProgress,
              !shutdownInProgress,
              needsRefresh,
              flowLedgerTask == nil else { return }
        flowLedgerTaskGeneration &+= 1
        let generation = flowLedgerTaskGeneration
        flowLedgerTask = Task { @MainActor [weak self] in
            await self?.runFlowLedgerRefreshLoop(generation: generation)
        }
    }

    private func cancelPresentationFlowLedgerRefresh() {
        guard !flowLedgerAccountingRefreshPending,
              !flowLedgerActiveBuildNeedsAccounting,
              flowLedgerTask != nil else { return }
        // Preserve the invalidated shared ledger for low-frequency background
        // consumers such as Automation, while restarting its build on the
        // slower hidden-surface cadence.
        flowLedgerPresentationRefreshPending = true
        flowLedgerTaskGeneration &+= 1
        flowLedgerTask?.cancel()
        flowLedgerTask = nil
        startFlowLedgerRefreshIfNeeded()
    }

    private func runFlowLedgerRefreshLoop(generation: UInt64) async {
        while !Task.isCancelled, generation == flowLedgerTaskGeneration {
            let hasPresentationDemand = presentationTelemetryPolicy.appRoutingActivity
            let needsAccounting = flowLedgerAccountingRefreshPending
            let needsPresentation = flowLedgerPresentationRefreshPending
            guard needsAccounting || needsPresentation else { break }
            do {
                // Coalesce connection and provider updates into one trailing
                // build. A single loop owns the detached worker, so stale
                // generations can never overlap on multiple utility threads.
                let delay: Duration = if hasPresentationDemand {
                    .milliseconds(350)
                } else if needsAccounting {
                    .seconds(2)
                } else {
                    .seconds(5)
                }
                try await Task.sleep(for: delay)
            } catch {
                break
            }
            guard !Task.isCancelled,
                  generation == flowLedgerTaskGeneration else { break }

            let buildNeedsAccounting = flowLedgerAccountingRefreshPending
            let buildNeedsPresentation = flowLedgerPresentationRefreshPending
            guard buildNeedsAccounting || buildNeedsPresentation else { continue }
            flowLedgerAccountingRefreshPending = false
            if buildNeedsPresentation {
                flowLedgerPresentationRefreshPending = false
            }
            flowLedgerActiveBuildNeedsAccounting = buildNeedsAccounting
            let revision = flowLedgerRevision
            let activeConnections = connections?.connections ?? []
            let closedConnections = recentlyClosedConnections.map {
                FlowLedgerClosedConnection(connection: $0.connection, closedAt: $0.closedAt)
            }
            let activities = appRoutingActivities
            let defaultProfileID = activeProfileID
            let worker = Task.detached(priority: .utility) {
                FlowLedger(
                    activeConnections: activeConnections,
                    recentlyClosedConnections: closedConnections,
                    appRoutingActivities: activities,
                    defaultProfileID: defaultProfileID
                )
            }
            let ledger = await withTaskCancellationHandler {
                await worker.value
            } onCancel: {
                worker.cancel()
            }
            guard !Task.isCancelled,
                  generation == flowLedgerTaskGeneration else { break }
            flowLedgerActiveBuildNeedsAccounting = false

            if revision == flowLedgerRevision {
                flowLedger = ledger
                appRoutingFlowEntries = Dictionary(
                    uniqueKeysWithValues: ledger.entries.compactMap {
                        entry -> (UUID, FlowLedgerEntry)? in
                        guard case let .appRouting(identifier) = entry.id else { return nil }
                        return (identifier, entry)
                    }
                )
                if buildNeedsAccounting {
                    schedulePersistentTrafficHistory(from: ledger)
                }
            } else if buildNeedsAccounting {
                // The build captured every completion which made accounting
                // dirty. Persist those deltas even if a later active-counter
                // update made the presentation revision stale; a successor
                // background build will publish the freshest shared ledger.
                schedulePersistentTrafficHistory(from: ledger)
            }
        }

        guard generation == flowLedgerTaskGeneration else { return }
        flowLedgerActiveBuildNeedsAccounting = false
        flowLedgerTask = nil
        if flowLedgerAccountingRefreshPending
            || flowLedgerPresentationRefreshPending {
            startFlowLedgerRefreshIfNeeded()
        }
    }

    private func schedulePersistentTrafficHistory(from ledger: FlowLedger) {
        guard trafficHistoryPersistenceChoice == .persistent,
              (persistentTrafficHistoryStore != nil
                || trafficHistoryPersistenceTransitionInProgress),
              !trafficHistoryClearInProgress,
              !shutdownInProgress,
              !ledger.entries.isEmpty else { return }

        for entry in ledger.entries {
            guard let completion = Self.trafficHistoryCompletion(entry) else { continue }
            let identifier = completion.checkpointIdentifier
            guard !persistedTrafficHistoryIdentifiers.contains(identifier),
                  queuedTrafficHistoryIdentifiers.insert(identifier).inserted else {
                continue
            }
            queuedTrafficHistoryCompletions.append(completion)
        }
        startPersistentTrafficHistoryWriterIfNeeded()
    }

    private func startPersistentTrafficHistoryWriterIfNeeded() {
        guard trafficHistoryPersistTask == nil,
              trafficHistoryPersistDrainTask == nil,
              persistentTrafficHistoryStore != nil,
              !trafficHistoryClearInProgress,
              !trafficHistoryPersistenceTransitionInProgress,
              !shutdownInProgress,
              !queuedTrafficHistoryCompletions.isEmpty else { return }

        trafficHistoryPersistGeneration &+= 1
        let generation = trafficHistoryPersistGeneration
        let operationGeneration = trafficHistoryPersistenceOperationGeneration
        trafficHistoryPersistTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while !Task.isCancelled,
                  generation == self.trafficHistoryPersistGeneration,
                  operationGeneration == self.trafficHistoryPersistenceOperationGeneration,
                  let store = self.persistentTrafficHistoryStore,
                  !self.queuedTrafficHistoryCompletions.isEmpty {
                let count = min(250, self.queuedTrafficHistoryCompletions.count)
                let batch = Array(self.queuedTrafficHistoryCompletions.prefix(count))
                do {
                    _ = try await store.ingest(batch)
                    guard !Task.isCancelled,
                          generation == self.trafficHistoryPersistGeneration,
                          operationGeneration == self.trafficHistoryPersistenceOperationGeneration else {
                        return
                    }
                    let now = Date()
                    if self.shouldPruneTrafficHistory(at: now) {
                        try await store.prune(now: now)
                        guard !Task.isCancelled,
                              generation == self.trafficHistoryPersistGeneration,
                              operationGeneration == self.trafficHistoryPersistenceOperationGeneration else {
                            return
                        }
                        self.trafficHistoryLastPrunedAt = now
                    }
                    self.queuedTrafficHistoryCompletions.removeFirst(count)
                    for completion in batch {
                        let identifier = completion.checkpointIdentifier
                        self.queuedTrafficHistoryIdentifiers.remove(identifier)
                        if self.persistedTrafficHistoryIdentifiers.insert(identifier).inserted {
                            self.persistedTrafficHistoryIdentifierOrder.append(identifier)
                        }
                    }
                    self.trimPersistedTrafficHistoryIdentifierCache()
                } catch {
                    guard !Task.isCancelled,
                          generation == self.trafficHistoryPersistGeneration,
                          operationGeneration == self.trafficHistoryPersistenceOperationGeneration else {
                        return
                    }
                    self.trafficHistoryPersistTask = nil
                    self.markPersistentTrafficHistoryUnavailable(
                        AppLocalization.format(
                            "MClash could not write the persistent traffic history: %@",
                            error.localizedDescription
                        )
                    )
                    return
                }
            }
            guard generation == self.trafficHistoryPersistGeneration,
                  operationGeneration == self.trafficHistoryPersistenceOperationGeneration else {
                return
            }
            if !Task.isCancelled {
                await self.refreshPersistentTrafficHistorySnapshots(
                    expectedPersistenceGeneration: generation,
                    expectedOperationGeneration: operationGeneration
                )
            }
            guard generation == self.trafficHistoryPersistGeneration,
                  operationGeneration == self.trafficHistoryPersistenceOperationGeneration else {
                return
            }
            self.trafficHistoryPersistTask = nil
            self.startPersistentTrafficHistoryWriterIfNeeded()
        }
    }

    private func trimPersistedTrafficHistoryIdentifierCache() {
        let maximumCount = 10_000
        guard persistedTrafficHistoryIdentifierOrder.count > maximumCount else { return }
        let overflow = persistedTrafficHistoryIdentifierOrder.count - maximumCount
        for identifier in persistedTrafficHistoryIdentifierOrder.prefix(overflow) {
            persistedTrafficHistoryIdentifiers.remove(identifier)
        }
        persistedTrafficHistoryIdentifierOrder.removeFirst(overflow)
    }

    private func beginTrafficHistoryMutation() async {
        guard trafficHistoryMutationInProgress else {
            trafficHistoryMutationInProgress = true
            return
        }
        await withCheckedContinuation { continuation in
            trafficHistoryMutationWaiters.append(continuation)
        }
    }

    private func endTrafficHistoryMutation() {
        guard !trafficHistoryMutationWaiters.isEmpty else {
            trafficHistoryMutationInProgress = false
            return
        }
        trafficHistoryMutationWaiters.removeFirst().resume()
    }

    private static func trafficHistoryCompletion(
        _ entry: FlowLedgerEntry
    ) -> TrafficHistoryCompletedFlow? {
        guard !entry.state.isActive, let completedAt = entry.endedAt else { return nil }

        let checkpoint: String
        let source: TrafficHistorySource
        switch entry.id {
        case let .appRouting(identifier):
            checkpoint = "app:\(identifier.uuidString)"
            source = .appRouting
        case let .mihomo(identifier):
            checkpoint = "mihomo:\(identifier)"
            source = .mihomo
        }

        return TrafficHistoryCompletedFlow(
            checkpointIdentifier: checkpoint,
            source: source,
            completedAt: completedAt,
            application: trafficHistoryApplication(entry.application),
            route: trafficHistoryRoute(entry),
            outcome: trafficHistoryOutcome(entry.outcome),
            upload: trafficHistoryMeasurement(entry.upload),
            download: trafficHistoryMeasurement(entry.download)
        )
    }

    private static func trafficHistoryApplication(
        _ application: FlowLedgerApplication
    ) -> TrafficHistoryApplication {
        if let bundleIdentifier = application.bundleIdentifier {
            return TrafficHistoryApplication(
                identity: .bundleIdentifier(bundleIdentifier),
                displayName: application.displayName
            )
        }
        if let signingIdentifier = application.signingIdentifier {
            return TrafficHistoryApplication(
                identity: .signingIdentifier(signingIdentifier),
                displayName: application.displayName
            )
        }
        return .unattributed
    }

    private static func trafficHistoryRoute(
        _ entry: FlowLedgerEntry
    ) -> TrafficHistoryRoute {
        switch entry.outcome {
        case .viaMihomo:
            guard let route = entry.mihomoRoute else { return .unresolved }
            return TrafficHistoryRoute(
                kind: .mihomo,
                displayName: route.chain.last ?? route.rule ?? "Mihomo",
                ruleName: route.rule,
                proxyChain: route.chain
            )
        case .direct:
            return TrafficHistoryRoute(kind: .direct, displayName: "Direct")
        case .rejected:
            return TrafficHistoryRoute(kind: .rejected, displayName: "Rejected")
        case .failOpen:
            return TrafficHistoryRoute(kind: .failOpen, displayName: "Fail-open")
        case .relayFailed:
            return TrafficHistoryRoute(
                kind: .relayFailed,
                displayName: "Relay failed",
                ruleName: entry.appRoutingRule
            )
        }
    }

    private static func trafficHistoryOutcome(
        _ outcome: FlowLedgerOutcome
    ) -> TrafficHistoryOutcome {
        switch outcome {
        case .viaMihomo: .viaMihomo
        case .direct: .direct
        case .rejected: .rejected
        case .failOpen: .failOpen
        case .relayFailed: .relayFailed
        }
    }

    private static func trafficHistoryMeasurement(
        _ measurement: FlowLedgerByteMeasurement
    ) -> TrafficHistoryMeasurement {
        switch measurement {
        case let .exact(bytes): .exact(bytes)
        case .notMeasuredAfterHandoff: .notMeasuredAfterHandoff
        case .notApplicable: .notApplicable
        }
    }

    private func cancelControllerStreamTasks() {
        trafficTask?.cancel()
        connectionsTask?.cancel()
        apiLogTask?.cancel()
        proxyRefreshTask?.cancel()
        liveFreshnessWatchdogTask?.cancel()
        trafficTask = nil
        connectionsTask = nil
        connectionStreamIntervalMilliseconds = nil
        apiLogTask = nil
        proxyRefreshTask = nil
        liveFreshnessWatchdogTask = nil
    }

    private func appendSupervisorLog(_ message: String) {
        appendCoreLog(CoreLogLine(stream: .supervisor, message: message))
    }

    private func recordStorageFailure(
        component: StorageInitializationFailure.Component,
        error: any Error,
        recoverySuggestion: String
    ) {
        storageInitializationFailures.removeAll { $0.component == component }
        storageInitializationFailures.append(
            StorageInitializationFailure(
                component: component,
                occurredAt: Date(),
                reason: error.localizedDescription,
                recoverySuggestion: recoverySuggestion
            )
        )
    }

    private func clearStorageFailure(for component: StorageInitializationFailure.Component) {
        storageInitializationFailures.removeAll { $0.component == component }
    }

    func applyProxyCollection(
        _ collection: MihomoProxyCollection,
        profileStructure providedProfileStructure: ProfileStructure? = nil
    ) {
        let profileStructure = providedProfileStructure ?? loadProxyProfileStructure()
        let topologyInput = ProxyTopologyInput(
            collection: collection,
            profileStructure: profileStructure
        )

        if proxiesByName != collection.proxies {
            proxiesByName = collection.proxies
        }
        if proxyProfileStructure != profileStructure {
            proxyProfileStructure = profileStructure
        }

        if proxyTopologyInput != topologyInput {
            let topology = ProxyTopologyBuilder().build(
                collection: collection,
                profileStructure: profileStructure
            )
            let selectionPaths = Dictionary(
                uniqueKeysWithValues: topology.groupOrder.map { groupName in
                    (
                        groupName,
                        ProxySelectionPathResolver().resolve(from: groupName, topology: topology)
                    )
                }
            )
            if proxyTopology != topology {
                proxyTopology = topology
            }
            if proxySelectionPaths != selectionPaths {
                proxySelectionPaths = selectionPaths
            }
            proxyTopologyInput = topologyInput
        }

        let currentNames = Set(collection.proxies.keys)
        var nextProxyDelays = proxyDelays.filter { currentNames.contains($0.key) }
        let nextContextualProxyDelays = contextualProxyDelays.filter { key, _ in
            currentNames.contains(key.group)
                && currentNames.contains(key.proxy)
                && collection.proxies[key.proxy]?
                    .extraDelayHistories[key.targetURL.absoluteString] == nil
        }
        let nextProxyGroups: [MihomoProxy] = proxyTopology.visibleGroupOrder.compactMap { name in
            guard name != "GLOBAL" else { return nil }
            return collection.proxies[name]
        }
        for proxy in collection.proxies.values {
            if let delay = proxy.history.last?.delay {
                if delay > 0 {
                    nextProxyDelays[proxy.name] = delay
                } else {
                    nextProxyDelays[proxy.name] = nil
                }
            }
        }
        if proxyDelays != nextProxyDelays {
            proxyDelays = nextProxyDelays
        }
        if contextualProxyDelays != nextContextualProxyDelays {
            contextualProxyDelays = nextContextualProxyDelays
        }
        if proxyGroups != nextProxyGroups {
            proxyGroups = nextProxyGroups
        }
        if let activeProfileID, let runtimeConfig {
            let snapshot = ProfileProxyWorkspaceSnapshotBuilder().build(
                profileID: activeProfileID,
                runtimeConfig: runtimeConfig,
                collection: collection,
                profileStructure: profileStructure,
                measuredDelays: profileProxyMeasuredDelays[activeProfileID] ?? [:]
            )
            profileProxyWorkspaceStates[activeProfileID] = .ready(snapshot)
        }
    }

    func proxyGroups(forRoutingMode rawMode: String) -> [MihomoProxy] {
        switch rawMode.lowercased() {
        case "direct":
            return []
        case "global":
            return proxiesByName["GLOBAL"].map { [$0] } ?? []
        default:
            guard globalProxyGroupIsRelevant,
                  let global = proxiesByName["GLOBAL"] else {
                return proxyGroups
            }
            return proxyGroups + [global]
        }
    }

    private func updateGlobalProxyGroupRelevance() {
        let next = rulesUseGlobalProxy || connectionsUseGlobalProxy
        if globalProxyGroupIsRelevant != next {
            globalProxyGroupIsRelevant = next
        }
    }

    private func loadProxyProfileStructure() -> ProfileStructure {
        guard let activeConfigURL,
              let data = try? Data(contentsOf: activeConfigURL) else {
            return .empty
        }
        return ProfileStructureReader().read(data: data)
    }

    func proxyDelay(for proxy: String, in group: String?) -> Int? {
        if let group, let target = delayTarget(forProxy: proxy, group: group) {
            if let delay = contextualProxyDelays[
                ProxyDelayContextKey(group: group, proxy: proxy, targetURL: target)
            ] {
                return delay
            }
            if let state = proxiesByName[proxy]?.extraDelayHistories[target.absoluteString],
               let latest = state.history?.last {
                return state.alive && latest.delay > 0 ? latest.delay : nil
            }
            return nil
        }
        return proxyDelays[proxy]
            ?? proxiesByName[proxy]?.history.last(where: { $0.delay > 0 })?.delay
    }

    func proxyDelayMap(for group: String) -> [String: Int] {
        guard let groupModel = proxiesByName[group] else { return [:] }
        return Dictionary(
            uniqueKeysWithValues: groupModel.all.compactMap { proxy in
                proxyDelay(for: proxy, in: group).map { (proxy, $0) }
            }
        )
    }

    func proxyAlive(for proxy: String, in group: String?) -> Bool? {
        guard let proxyModel = proxiesByName[proxy] else { return nil }
        if let group,
           let target = delayTarget(forProxy: proxy, group: group),
           let state = proxyModel.extraDelayHistories[target.absoluteString] {
            return state.alive
        }
        return proxyModel.alive
    }

    func applyConnectionSnapshot(_ snapshot: MihomoConnectionSnapshot, generation: Int) {
        guard presentationTelemetryPolicy.connections else {
            trafficAttribution.reset()
            if !routeTrafficEntries.isEmpty {
                routeTrafficEntries = []
            }
            connections = snapshot
            return
        }
        _ = trafficAttribution.ingest(
            connections: snapshot.connections,
            generation: generation
        )
        routeTrafficEntries = trafficAttribution.entries
        connections = snapshot
    }

    nonisolated private static func normalizedConnectionSnapshot(
        _ snapshot: MihomoConnectionSnapshot
    ) -> MihomoConnectionSnapshot {
        MihomoConnectionSnapshot(
            downloadTotal: snapshot.downloadTotal,
            uploadTotal: snapshot.uploadTotal,
            connections: snapshot.connections.sorted {
                if $0.start == $1.start { return $0.id < $1.id }
                return $0.start > $1.start
            },
            memory: snapshot.memory
        )
    }

    private func delayTarget(forProxy proxy: String, group groupName: String?) -> URL? {
        if let groupName,
           let group = proxiesByName[groupName],
           let target = delayTarget(for: group) {
            return target
        }
        if let proxyModel = proxiesByName[proxy], let target = delayTarget(for: proxyModel) {
            return target
        }
        if let group = proxyGroups.first(where: { $0.all.contains(proxy) }),
           let target = delayTarget(for: group) {
            return target
        }
        return defaultDelayTarget
    }

    private func expectedDelayStatus(forProxy proxy: String, group groupName: String?) -> String? {
        if let groupName,
           let group = proxiesByName[groupName],
           let status = normalizedExpectedStatus(group.expectedStatus) {
            return status
        }
        if let status = normalizedExpectedStatus(proxiesByName[proxy]?.expectedStatus) {
            return status
        }
        let group = proxyGroups.first { $0.all.contains(proxy) }
        return normalizedExpectedStatus(group?.expectedStatus)
    }

    private func delayTarget(for proxy: MihomoProxy) -> URL? {
        if let value = proxy.testURL?.trimmingCharacters(in: .whitespacesAndNewlines),
           !value.isEmpty,
           let url = URL(string: value) {
            return url
        }
        return nil
    }

    private func normalizedExpectedStatus(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return nil
        }
        return value
    }

    private var defaultDelayTarget: URL {
        URL(string: "https://www.gstatic.com/generate_204")!
    }

    private func recordOperationFailure(_ error: Error, context: String) {
        let message = error.localizedDescription
        errorMessage = message
        appendSupervisorLog("\(context) failed: \(message)")
    }

    private func redactedSubscriptionMessage(_ message: String, url: URL?) -> String {
        guard let url else { return message }
        var redacted = message.replacingOccurrences(
            of: url.absoluteString,
            with: AppLocalization.string("the subscription endpoint"),
            options: .caseInsensitive
        )
        if let host = url.host, !host.isEmpty {
            redacted = redacted.replacingOccurrences(
                of: host,
                with: AppLocalization.string("the subscription host"),
                options: .caseInsensitive
            )
        }
        return redacted
    }

    private func appendCoreLog(_ line: CoreLogLine) {
        pendingCoreLogs.append(line)
        if pendingCoreLogs.count >= 64 {
            flushPendingCoreLogs()
            return
        }
        guard coreLogFlushTask == nil else { return }
        coreLogFlushTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(80))
            } catch {
                return
            }
            guard let self, !Task.isCancelled else { return }
            self.coreLogFlushTask = nil
            self.flushPendingCoreLogs()
        }
    }

    private func flushPendingCoreLogs() {
        coreLogFlushTask?.cancel()
        coreLogFlushTask = nil
        guard !pendingCoreLogs.isEmpty else { return }
        logs.append(contentsOf: pendingCoreLogs)
        pendingCoreLogs.removeAll(keepingCapacity: true)
        if logs.count > 1_500 {
            // Trim in batches so a noisy core does not shift the full observable array
            // for every batch after reaching the display limit.
            logs.removeFirst(logs.count - 1_350)
        }
    }

    @discardableResult
    private func begin(_ operation: Operation) -> Bool {
        guard !shutdownInProgress else { return false }
        guard canPerform(operation) else { return false }
        return operations.insert(operation).inserted
    }

    private func end(_ operation: Operation) {
        operations.remove(operation)
    }

    func setQuickRoutePinned(
        _ name: String,
        pinned: Bool,
        availableNames: [String]? = nil
    ) {
        let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedName.isEmpty else { return }

        let availableSet = availableNames.map { names in
            Set(names.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) })
        }
        if pinned, let availableSet, !availableSet.contains(normalizedName) {
            return
        }
        var names = pinnedQuickRouteNames.filter {
            $0 != normalizedName && (availableSet?.contains($0) ?? true)
        }
        if pinned {
            guard names.count < QuickRouteSelectionPolicy.maximumVisibleRoutes else { return }
            names.append(normalizedName)
        }
        names = Self.normalizedQuickRouteNames(names)
        guard names != pinnedQuickRouteNames else { return }
        pinnedQuickRouteNames = names
        preferenceDefaults.set(names, forKey: Self.pinnedQuickRouteNamesKey)
    }

    func clearPinnedQuickRoutes() {
        guard !pinnedQuickRouteNames.isEmpty else { return }
        pinnedQuickRouteNames = []
        preferenceDefaults.removeObject(forKey: Self.pinnedQuickRouteNamesKey)
    }

    private static func normalizedQuickRouteNames(_ names: [String]) -> [String] {
        var seen = Set<String>()
        let normalized: [String] = names.compactMap { rawName in
            let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, seen.insert(name).inserted else { return nil }
            return name
        }
        return Array(normalized.prefix(QuickRouteSelectionPolicy.maximumVisibleRoutes))
    }

    private func systemProxySnapshotURL(layout: ProfileDirectoryLayout) -> URL {
        layout.stateDirectory.appending(path: "system-proxy-snapshot.json")
    }

    private func positivePort(_ port: Int) -> Int? {
        port > 0 ? port : nil
    }

    /// Validates the invariant shared by startup, reconnect, and Workspace
    /// activation: the strategy-owned HTTP/SOCKS listeners must not bind the
    /// port reserved for MClash's stable managed Mixed endpoint. Keeping this
    /// check at the runtime boundary is important because the compiler emits
    /// the policy document without the runtime-only Mixed override.
    private func repairManagedMixedPortCollision(
        compiled: CompiledConfiguration? = nil
    ) async throws {
        guard unifiedConfigurationEnabled,
              let managedPort = positivePort(profileRuntimePlan.defaultMixedPort)
        else { return }
        let candidate: CompiledConfiguration
        if let compiled {
            candidate = compiled
        } else {
            guard let current = try compiledConfigurationForCurrentWorkspace() else {
                return
            }
            candidate = current
        }
        let boundPorts = try RuntimeConfigurationComposer().boundListenerPorts(in: candidate.yaml)
        guard boundPorts.contains(managedPort) else {
            return
        }
        var excluded = boundPorts
        excluded.formUnion(profileRuntimePlan.sessions.map(\.mixedPort))
        excluded.formUnion(profileRuntimePlan.routeListeners.map(\.port))
        excluded.remove(managedPort)
        let replacement = try localPortProbe.availableTCPAndUDPPorts(
            count: 1,
            excluding: excluded
        )[0]
        var candidatePlan = profileRuntimePlan
        candidatePlan.defaultMixedPort = replacement
        try ProfileRuntimePlanValidator().validate(candidatePlan)
        guard let store = profileRuntimePlanStore else {
            throw AppModelError.profileStoreUnavailable
        }
        try await store.save(candidatePlan)
        profileRuntimePlan = candidatePlan
        appendSupervisorLog(
            AppLocalization.format(
                "The managed Mixed port %@ conflicted with a configured entrance; MClash moved it to %@.",
                String(managedPort),
                String(replacement)
            )
        )
    }

    private func mixedPortIsAvailableForStart(
        _ port: Int,
        profileID: ProfileID
    ) -> Bool {
        if localPortProbe.isAvailableTCPAndUDP(port: port) {
            return true
        }
        guard verifiedMClashMixedPorts[profileID]?.contains(port) == true else {
            return false
        }
        // A raw TCP bind can remain unavailable briefly after our listener
        // stops. Reuse is safe only when no TCP listener answers on either
        // loopback family and UDP is completely free. The authenticated
        // controller check after launch remains authoritative.
        return !localPortProbe.isListening(port: port)
            && localPortProbe.isAvailableUDP(port: port)
    }

    private var activeNetworkExtensionMihomoListener: NetworkExtensionMihomoListenerConfiguration? {
        guard networkCapturePreferences.enabled,
              let listener = networkExtensionMihomoListener else { return nil }
        guard unifiedConfigurationEnabled else { return listener }
        return sanitizedUnifiedNetworkExtensionListener(listener)
    }

    private func sanitizedUnifiedNetworkExtensionListener(
        _ listener: NetworkExtensionMihomoListenerConfiguration
    ) -> NetworkExtensionMihomoListenerConfiguration? {
        let validNames = unifiedRuntimeProxyNames()
        let retainedRoutes = Set(
            listener.routeListeners.compactMap { routeListener -> MihomoRoute? in
                unifiedRuntimeRouteIsValid(
                    routeListener.route,
                    proxyNames: validNames
                ) ? routeListener.route : nil
            }
        )
        guard retainedRoutes.count != listener.routeListeners.count else {
            return listener
        }
        return try? listener.retaining(routes: retainedRoutes)
    }

    private var activeProfileDedicatedMixedListener:
        ManagedProfileMixedListenerConfiguration?
    {
        guard let activeProfileID,
              let session = profileSessionSpec(for: activeProfileID),
              session.enabled
        else { return nil }
        return try? ManagedProfileMixedListenerConfiguration(
            port: session.mixedPort
        )
    }

    private func primarySourceBoundListenerPorts(
        profileID: ProfileID
    ) async throws -> Set<Int> {
        guard let profileStore else {
            throw AppModelError.profileStoreUnavailable
        }
        if let compiled = try compiledConfigurationForCurrentWorkspace() {
            var ports = try RuntimeConfigurationComposer().boundListenerPorts(in: compiled.yaml)
            if unifiedConfigurationEnabled {
                ports.insert(profileRuntimePlan.defaultMixedPort)
            }
            return ports
        }
        let composer = RuntimeConfigurationComposer()
        if unifiedConfigurationEnabled {
            guard let compiledConfiguration else {
                throw AppModelError.profileStoreUnavailable
            }
            var ports = try composer.boundListenerPorts(in: compiledConfiguration.yaml)
            ports.insert(profileRuntimePlan.defaultMixedPort)
            return ports
        }
        let sourceData = try await profileStore.configurationData(for: profileID)
        let managedSourceData = try composer.sanitizingForManagedSession(sourceData)
        let sourceCandidate = try composer.applying(
            effectiveRuntimeOverrides(for: profileID),
            to: managedSourceData,
            networkExtensionListener: nil,
            profileMixedListener: activeProfileDedicatedMixedListener,
            routeListeners: profileRouteListeners(for: profileID)
        )
        return try composer.boundListenerPorts(in: sourceCandidate)
    }

    private func activeNetworkExtensionRouteProxyEndpoints() throws
        -> [MihomoRouteProxyEndpoint]
    {
        let endpoints = try networkExtensionProfileListeners
            .sorted { $0.key.description < $1.key.description }
            .flatMap { try $0.value.routeProxyEndpoints() }
        try MihomoRouteProxyCatalog.validate(endpoints)
        return endpoints
    }

    private var networkCaptureIsActive: Bool {
        switch networkCaptureState {
        case .enabling, .awaitingUserApproval, .on, .disabling, .failed:
            true
        case .off, .waitingForConnection, .requiresReboot:
            false
        }
    }

    private var networkCaptureNeedsActivation: Bool {
        switch networkCaptureState {
        case let .on(revision):
            revision != networkCapturePreferences.snapshot.revision
        case .off, .waitingForConnection, .enabling, .awaitingUserApproval, .failed:
            true
        case .disabling, .requiresReboot:
            false
        }
    }

    private func loadProfileRuntimePlan() async throws {
        guard let store = profileRuntimePlanStore else {
            profileRuntimePlan = .empty
            return
        }

        let recovery = try await store.loadRecoveringInvalidDocument()
        var plan = recovery.plan
        if let reason = recovery.recoveryReason,
           let quarantinedURL = recovery.quarantinedURL {
            recordStorageFailure(
                component: .profileRuntimePlan,
                error: AppModelError.profileActivationFailed(reason),
                recoverySuggestion: AppLocalization.format(
                    "MClash preserved the invalid document at %@ and regenerated a safe plan for the current default profile. Review the per-profile Mixed ports before re-enabling auxiliary sessions.",
                    quarantinedURL.path
                )
            )
            appendSupervisorLog(
                "Invalid profile runtime plan was quarantined at \(quarantinedURL.path)."
            )
        } else {
            clearStorageFailure(for: .profileRuntimePlan)
        }
        let knownProfileIDs = Set(profiles.map(\.id))
        plan.sessions.removeAll { !knownProfileIDs.contains($0.profileID) }
        plan.routeListeners.removeAll { !knownProfileIDs.contains($0.profileID) }

        if let activeProfileID {
            // A fresh virtual Default Profile adopts the source Profile's
            // existing Mixed port when it is safe. This preserves the address
            // users and developer tools already configured, while the real
            // Profile receives a separate dedicated port below.
            if plan.sessions.isEmpty,
               let profileStore,
               let data = try? await profileStore.configurationData(
                   for: activeProfileID
               ),
               let ports = try? RuntimeConfigurationComposer().listenerPorts(
                   in: data
               ),
               let sourceMixedPort = ports.mixedPort,
               (1...65_535).contains(sourceMixedPort),
               localPortProbe.isAvailableTCPAndUDP(port: sourceMixedPort) {
                plan.defaultMixedPort = sourceMixedPort
            }
            if !plan.sessions.contains(where: { $0.profileID == activeProfileID }) {
                let port = try await preferredMixedPort(
                    for: activeProfileID,
                    excluding: Set(
                        plan.sessions.map(\.mixedPort) + [plan.defaultMixedPort]
                            + plan.routeListeners.map(\.port)
                    )
                )
                plan.sessions.append(ProfileSessionSpec(
                    profileID: activeProfileID,
                    enabled: false,
                    mixedPort: port
                ))
            }
            plan.primaryProfileID = activeProfileID
        } else {
            plan.primaryProfileID = nil
        }

        try await store.save(plan)
        profileRuntimePlan = plan
    }

    func profileSessionSpec(for profileID: ProfileID) -> ProfileSessionSpec? {
        profileRuntimePlan.sessions.first { $0.profileID == profileID }
    }

    func profileRouteListeners(
        for profileID: ProfileID
    ) -> [ProfileRouteListenerSpec] {
        if unifiedConfigurationEnabled { return [] }
        return profileRuntimePlan.routeListeners.filter { $0.profileID == profileID }
    }

    func setProfileMixedPortEnabled(
        profileID: ProfileID,
        enabled: Bool
    ) async throws {
        let mixedPort: Int
        if let session = profileSessionSpec(for: profileID) {
            mixedPort = session.mixedPort
        } else {
            mixedPort = try await preferredMixedPort(
                for: profileID,
                excluding: Set(
                    profileRuntimePlan.sessions.map(\.mixedPort)
                        + [profileRuntimePlan.defaultMixedPort]
                        + profileRuntimePlan.routeListeners.map(\.port)
                )
            )
        }
        try await updateProfileRuntime(
            profileID: profileID,
            enabled: enabled,
            mixedPort: mixedPort
        )
    }

    func updateProfileRuntime(
        profileID: ProfileID,
        enabled: Bool,
        mixedPort: Int
    ) async throws {
        guard begin(.updateProfile(profileID)) else {
            throw AppModelError.operationInProgress
        }
        defer { end(.updateProfile(profileID)) }
        guard profiles.contains(where: { $0.id == profileID }),
              let store = profileRuntimePlanStore else {
            throw AppModelError.profileStoreUnavailable
        }
        if !enabled, networkCapturePreferences.snapshot.rules.contains(where: { rule in
            guard rule.enabled,
                  case let .mihomo(route) = rule.action,
                  let target = route.routingProfileID else { return false }
            return target.uuid == profileID.rawValue
        }) {
            throw AppModelError.profileRequiredByAppRouting(profileDisplayName(profileID))
        }

        let previousPlan = profileRuntimePlan
        var candidate = profileRuntimePlan
        if let index = candidate.sessions.firstIndex(where: {
            $0.profileID == profileID
        }) {
            candidate.sessions[index].enabled = enabled
            candidate.sessions[index].mixedPort = mixedPort
        } else {
            candidate.sessions.append(ProfileSessionSpec(
                profileID: profileID,
                enabled: enabled,
                mixedPort: mixedPort
            ))
        }
        candidate.primaryProfileID = activeProfileID
        try ProfileRuntimePlanValidator().validate(candidate)
        profileRuntimePlan = candidate

        let wasConnected = isConnected || isBusy
        let systemProxyWasOn = systemProxyEnabled
        do {
            if profileID == activeProfileID, wasConnected {
                guard await performDisconnect() else {
                    throw AppModelError.profileActivationFailed(
                        AppLocalization.string(
                            "The active core could not stop before its Mixed port changed."
                        )
                    )
                }
            }
            try await prepareProfileRoutingSessions(
                for: networkCapturePreferences.enabled
                    ? networkCapturePreferences.snapshot.rules
                    : [],
                startAuxiliary: wasConnected
            )
            if profileID == activeProfileID {
                let activation = try await activateStoredProfile(
                    profileID,
                    validator: try makeProfileValidator()
                )
                activeConfigURL = activation.configurationURL
            }
            if profileID == activeProfileID, wasConnected {
                guard await performConnect() else {
                    throw AppModelError.profileActivationFailed(
                        AppLocalization.string(
                            "The active core could not restart on its new Mixed port."
                        )
                    )
                }
                if systemProxyWasOn {
                    await performEnableSystemProxy()
                    guard systemProxyState == .on else {
                        throw AppModelError.profileActivationFailed(
                            errorMessage
                                ?? AppLocalization.string(
                                    "The macOS system proxy could not be restored after the port change."
                                )
                        )
                    }
                }
            }
            try await store.save(candidate)
        } catch let updateError {
            var rollbackFailures: [String] = []
            profileRuntimePlan = previousPlan
            do {
                try await store.save(previousPlan)
            } catch {
                rollbackFailures.append(
                    AppLocalization.format(
                        "the previous profile runtime plan could not be saved: %@",
                        error.localizedDescription
                    )
                )
            }

            if profileID == activeProfileID, isConnected || isBusy {
                if !(await performDisconnect()) {
                    rollbackFailures.append(
                        AppLocalization.string(
                            "the candidate core could not be stopped before rollback"
                        )
                    )
                }
            }
            do {
                try await prepareProfileRoutingSessions(
                    for: networkCapturePreferences.enabled
                        ? networkCapturePreferences.snapshot.rules
                        : [],
                    startAuxiliary: wasConnected
                )
                if profileID == activeProfileID {
                    let rollback = try await activateStoredProfile(
                        profileID,
                        validator: try makeProfileValidator()
                    )
                    activeConfigURL = rollback.configurationURL
                    if wasConnected, !(await performConnect()) {
                        rollbackFailures.append(
                            AppLocalization.string(
                                "the previous active profile could not be reconnected"
                            )
                        )
                    }
                    if wasConnected, systemProxyWasOn {
                        await performEnableSystemProxy()
                        if systemProxyState != .on {
                            rollbackFailures.append(
                                AppLocalization.string(
                                    "the previous macOS system proxy could not be restored"
                                )
                            )
                        }
                    }
                }
            } catch {
                rollbackFailures.append(
                    AppLocalization.format(
                        "the previous profile runtime could not be restored: %@",
                        error.localizedDescription
                    )
                )
            }

            guard rollbackFailures.isEmpty else {
                throw NetworkCaptureTransactionFailure(
                    updateReason: updateError.localizedDescription,
                    rollbackReason: rollbackFailures.joined(separator: "; ")
                )
            }
            throw updateError
        }
    }

    private func preferredMixedPort(
        for profileID: ProfileID,
        excluding usedPorts: Set<Int>
    ) async throws -> Int {
        if let profileStore,
           let data = try? await profileStore.configurationData(for: profileID),
           let configured = try? RuntimeConfigurationComposer().listenerPorts(in: data),
           let mixedPort = configured.mixedPort,
           (1...65_535).contains(mixedPort),
           !usedPorts.contains(mixedPort),
           localPortProbe.isAvailableTCPAndUDP(port: mixedPort) {
            return mixedPort
        }

        for _ in 0..<64 {
            let port = try localPortProbe.availableTCPAndUDPPorts(count: 1)[0]
            if !usedPorts.contains(port) { return port }
        }
        throw AppModelError.localProxyPortsUnavailable
    }

    private func effectiveRuntimeOverrides(for profileID: ProfileID) -> RuntimeOverrides {
        if unifiedConfigurationEnabled {
            return compiledRuntimeOverrides(for: profileID)
        }
        // Advanced runtime overrides belong to the active profile. Applying
        // its DNS, rules, interface, or LAN policy to another airport would
        // silently merge two otherwise independent profiles. Auxiliary
        // sessions therefore inherit their own source configuration, with
        // only MClash-owned listener isolation layered on top.
        var overrides = profileID == activeProfileID
            ? runtimeOverrides
            : RuntimeOverrides(
                ports: RuntimePortOverrides(
                    port: 0,
                    socksPort: 0,
                    redirPort: 0,
                    tproxyPort: 0
                ),
                allowLAN: false,
                bindAddress: "127.0.0.1",
                dns: RuntimeDNSOverrides(enable: false)
            )
        overrides.ports.port = 0
        overrides.ports.socksPort = 0
        overrides.ports.mixedPort = profileID == activeProfileID
            ? profileRuntimePlan.defaultMixedPort
            : profileSessionSpec(for: profileID)?.mixedPort
        return overrides
    }

    /// The unified compiler owns every policy field, but the core fleet still
    /// needs one managed Mixed listener for local tools, system proxy
    /// compatibility, and the Network Extension relay. Keep that listener as
    /// a runtime-only override so it never leaks back into source YAML.
    private func compiledRuntimeOverrides(for profileID: ProfileID) -> RuntimeOverrides {
        let mixedPort = profileID == activeProfileID
            ? profileRuntimePlan.defaultMixedPort
            : profileSessionSpec(for: profileID)?.mixedPort
        return RuntimeOverrides(
            ports: RuntimePortOverrides(mixedPort: mixedPort)
        )
    }

    private func prepareProfileRoutingSessions(
        for rules: [CaptureRule],
        captureEnabled: Bool? = nil,
        startAuxiliary: Bool = true
    ) async throws {
        guard !shutdownInProgress else { throw CancellationError() }
        if !unifiedConfigurationEnabled {
            try await validateProfileRouteListenerTargets(
                profileRuntimePlan.routeListeners
            )
        }
        guard let activeProfileID,
              let profileStore,
              let profileLayout else {
            networkExtensionMihomoListener = nil
            networkExtensionProfileListeners = [:]
            _ = await coreFleet.stopAll()
            auxiliaryCoreStates = await coreFleet.states()
            return
        }

        let shouldConfigureCapture = captureEnabled ?? networkCapturePreferences.enabled
        let effectiveRules = unifiedConfigurationEnabled ? try unifiedCaptureRules() : rules
        try await ensureRuntimePlanCovers(
            activeProfileID: activeProfileID,
            rules: shouldConfigureCapture ? effectiveRules : []
        )

        var routesByProfile: [ProfileID: Set<MihomoRoute>] = [:]
        if shouldConfigureCapture {
            for rule in effectiveRules where rule.enabled {
                guard case let .mihomo(route) = rule.action else { continue }
                if let target = route.routingProfileID {
                    let profileID = ProfileID(rawValue: target.uuid)
                    routesByProfile[profileID, default: []].insert(route)
                } else if route != .profileRules {
                    routesByProfile[activeProfileID, default: []].insert(route)
                }
            }
        }

        var listeners: [ProfileID: NetworkExtensionMihomoListenerConfiguration] = [:]
        if shouldConfigureCapture {
            let primarySourcePorts = try await primarySourceBoundListenerPorts(
                profileID: activeProfileID
            )
            var requests: [(
                profileID: ProfileID,
                routes: Set<MihomoRoute>,
                includesLegacyProfileRules: Bool
            )] = [(
                profileID: activeProfileID,
                routes: routesByProfile[activeProfileID] ?? [],
                includesLegacyProfileRules: true
            )]
            requests += routesByProfile
                .filter { $0.key != activeProfileID && !$0.value.isEmpty }
                .map {
                    (
                        profileID: $0.key,
                        routes: $0.value,
                        includesLegacyProfileRules: false
                    )
                }
            let requestedProfileIDs = Set(requests.map(\.profileID))
            if !unifiedConfigurationEnabled {
                requests += networkExtensionProfileListeners.compactMap {
                    profileID, existing in
                    guard !requestedProfileIDs.contains(profileID),
                          profiles.contains(where: { $0.id == profileID })
                    else { return nil }
                    return (
                        profileID: profileID,
                        routes: Set<MihomoRoute>(),
                        includesLegacyProfileRules:
                            existing.includesLegacyProfileRules
                    )
                }
            }
            requests.sort { $0.profileID.description < $1.profileID.description }

            var listenerPorts = Set(
                profileRuntimePlan.enabledSessions.map(\.mixedPort)
            ).union(primarySourcePorts)
                .union(
                    profileRuntimePlan.routeListeners
                        .filter(\.enabled)
                        .map(\.port)
                )
            var requestsNeedingPorts: [(
                profileID: ProfileID,
                routes: Set<MihomoRoute>,
                includesLegacyProfileRules: Bool,
                existing: NetworkExtensionMihomoListenerConfiguration?
            )] = []
            for request in requests {
                if let existing = reusableNetworkExtensionMihomoListener(
                    routes: request.routes,
                    includesLegacyProfileRules: request.includesLegacyProfileRules,
                    existing: networkExtensionProfileListeners[request.profileID],
                    excluding: listenerPorts
                ) {
                    listeners[request.profileID] = existing
                    listenerPorts.formUnion(
                        existing.routeListeners.map { Int($0.port) }
                    )
                } else {
                    let expandable = compatibleNetworkExtensionMihomoListener(
                        includesLegacyProfileRules: request.includesLegacyProfileRules,
                        existing: networkExtensionProfileListeners[request.profileID],
                        excluding: listenerPorts
                    )
                    requestsNeedingPorts.append((
                        profileID: request.profileID,
                        routes: request.routes,
                        includesLegacyProfileRules: request.includesLegacyProfileRules,
                        existing: expandable
                    ))
                }
            }

            let requiredPortCount = requestsNeedingPorts.reduce(into: 0) {
                var requiredRoutes = $1.routes
                if $1.includesLegacyProfileRules {
                    requiredRoutes.insert(.profileRules)
                }
                let existingRoutes = Set(
                    $1.existing?.routeListeners.map(\.route) ?? []
                )
                $0 += requiredRoutes.subtracting(existingRoutes).count
            }
            var allocatedPorts: ArraySlice<Int> = requiredPortCount > 0
                ? try localPortProbe.availableTCPAndUDPPorts(
                    count: requiredPortCount,
                    excluding: listenerPorts
                )[...]
                : []
            for request in requestsNeedingPorts {
                var requiredRoutes = request.routes
                if request.includesLegacyProfileRules {
                    requiredRoutes.insert(.profileRules)
                }
                let existingRoutes = Set(
                    request.existing?.routeListeners.map(\.route) ?? []
                )
                let count = requiredRoutes.subtracting(existingRoutes).count
                let ports = Array(allocatedPorts.prefix(count))
                allocatedPorts = allocatedPorts.dropFirst(count)
                let listener = if let existing = request.existing {
                    try expandNetworkExtensionMihomoListener(
                        routes: request.routes,
                        includesLegacyProfileRules: request.includesLegacyProfileRules,
                        existing: existing,
                        ports: ports
                    )
                } else {
                    try makeNetworkExtensionMihomoListener(
                        routes: request.routes,
                        includesLegacyProfileRules: request.includesLegacyProfileRules,
                        ports: ports
                    )
                }
                listeners[request.profileID] = listener
                listenerPorts.formUnion(listener.routeListeners.map { Int($0.port) })
            }
        }
        // A live listener may intentionally retain an idle route endpoint, but
        // it must never retain an outbound proxy name that no longer exists in
        // the authoritative MClash workspace.  This commonly happens when a
        // legacy "MClash Select" group is renamed by the preset migration:
        // Mihomo's syntax checker accepts the stale string, while a real relay
        // fails later with "unknown proxy group".  Prune only invalid policy
        // routes and keep the endpoint/credential material for valid ones.
        if unifiedConfigurationEnabled {
            let validNames = unifiedRuntimeProxyNames()
            var sanitized: [ProfileID: NetworkExtensionMihomoListenerConfiguration] = [:]
            for (profileID, listener) in listeners {
                let retainedRoutes = Set(
                    listener.routeListeners.compactMap { routeListener -> MihomoRoute? in
                        unifiedRuntimeRouteIsValid(
                            routeListener.route,
                            proxyNames: validNames
                        ) ? routeListener.route : nil
                    }
                )
                if retainedRoutes.count == listener.routeListeners.count {
                    sanitized[profileID] = listener
                } else if let narrowed = try? listener.retaining(routes: retainedRoutes) {
                    sanitized[profileID] = narrowed
                }
            }
            listeners = sanitized
        }
        networkExtensionProfileListeners = listeners
        networkExtensionMihomoListener = listeners[activeProfileID]

        let shouldStartAuxiliary = startAuxiliary && !unifiedConfigurationEnabled
        let auxiliarySpecs = profileRuntimePlan.enabledSessions.filter {
            $0.profileID != activeProfileID
        }
        let auxiliaryPlan = ProfileRuntimePlan(
            sessions: shouldStartAuxiliary ? auxiliarySpecs : [],
            primaryProfileID: nil
        )
        var launchConfigurations: [ProfileID: CoreLaunchConfiguration] = [:]
        var preexistingRunningProfiles = Set<ProfileID>()
        if shouldStartAuxiliary {
            let binaryURL = try binaryLocator.locate()
            var reservedControllerPorts = Set(
                profileRuntimePlan.enabledSessions.map(\.mixedPort)
                    + profileRuntimePlan.routeListeners
                        .filter(\.enabled)
                        .map(\.port)
                    + listeners.values.flatMap {
                        $0.routeListeners.map { Int($0.port) }
                    }
                    + auxiliaryLaunchConfigurations.values.map {
                        Int($0.controllerPort)
                    }
            )
            for spec in auxiliarySpecs {
                let fleetState = await coreFleet.state(for: spec.profileID)
                let runningSession: CoreSession? = if case let .running(session)? = fleetState {
                    session
                } else {
                    nil
                }
                if runningSession != nil {
                    preexistingRunningProfiles.insert(spec.profileID)
                }
                let sessionOwnsPort: Bool
                if let runningSession {
                    do {
                        let client = try MihomoAPIClient(
                            baseURL: runningSession.endpoint,
                            secret: runningSession.secret
                        )
                        sessionOwnsPort = try await client.fetchConfig().mixedPort
                            == spec.mixedPort
                    } catch {
                        // A running state alone is not port ownership. If its
                        // authenticated controller cannot prove the exact
                        // requested listener, fall through to the full
                        // IPv4/IPv6 TCP and UDP availability checks.
                        sessionOwnsPort = false
                    }
                } else {
                    sessionOwnsPort = false
                }
                if !sessionOwnsPort,
                   !mixedPortIsAvailableForStart(
                       spec.mixedPort,
                       profileID: spec.profileID
                   ) {
                    throw AppModelError.profileMixedPortUnavailable(
                        profileDisplayName(spec.profileID),
                        spec.mixedPort
                    )
                }
                let listener = listeners[spec.profileID]
                let sourceData = try await profileStore.configurationData(for: spec.profileID)
                let isolatedSourceData = try RuntimeConfigurationComposer()
                    .sanitizingForManagedSession(sourceData)
                let runtimeData = try RuntimeConfigurationComposer().applying(
                    effectiveRuntimeOverrides(for: spec.profileID),
                    to: isolatedSourceData,
                    networkExtensionListener: listener,
                    routeListeners: profileRouteListeners(for: spec.profileID)
                )
                let configurationURL = profileLayout.runtimeConfigurationURL(
                    for: spec.profileID
                )
                if let runningSession,
                   let existing = auxiliaryLaunchConfigurations[spec.profileID] {
                    let client = try MihomoAPIClient(
                        baseURL: runningSession.endpoint,
                        secret: runningSession.secret
                    )
                    _ = try await hotReloadRuntimeConfiguration(
                        runtimeData,
                        destinationURL: configurationURL,
                        stagingDirectory: profileLayout.runtimeStagingDirectory(
                            for: spec.profileID
                        ),
                        client: client,
                        verification: {
                            _ = try await client.fetchConfig()
                            if let listener,
                               let authentication = listener.authentication {
                                try await self.localPortProbe
                                    .waitUntilAuthenticatedSOCKS5Proxy(
                                        ports: Set(
                                            listener.routeListeners.map {
                                                Int($0.port)
                                            }
                                        ),
                                        authentication: authentication
                                    )
                            }
                        }
                    )
                    launchConfigurations[spec.profileID] = existing
                    continue
                }
                let changed = try await persistAuxiliaryRuntimeConfiguration(
                    runtimeData,
                    profileID: spec.profileID,
                    destinationURL: configurationURL
                )
                if !changed,
                   let existing = auxiliaryLaunchConfigurations[spec.profileID] {
                    launchConfigurations[spec.profileID] = existing
                    continue
                }

                try profileLayout.createRuntimeDirectories(for: spec.profileID)
                let homeDirectory = profileLayout.coreHomeDirectory(for: spec.profileID)
                try geoDataInstaller.installIfNeeded(into: homeDirectory)
                let controllerPort = try availableTCPPort(
                    excluding: reservedControllerPorts
                )
                reservedControllerPorts.insert(controllerPort)
                let configuration = CoreLaunchConfiguration(
                    binaryURL: binaryURL,
                    homeDirectory: homeDirectory,
                    configURL: configurationURL,
                    controllerPort: UInt16(controllerPort),
                    secret: try secureRandomString()
                )
                launchConfigurations[spec.profileID] = configuration
            }
        }

        guard !shutdownInProgress else { throw CancellationError() }
        let result = try await coreFleet.reconcile(
            plan: auxiliaryPlan,
            launchConfigurations: launchConfigurations
        )
        auxiliaryCoreStates = await coreFleet.states()
        if !result.failures.isEmpty {
            for profileID in result.failures.keys {
                auxiliaryLaunchConfigurations[profileID] = nil
            }
            let detail = result.failures.sorted {
                $0.key.description < $1.key.description
            }.map {
                "\(profileDisplayName($0.key)): \($0.value)"
            }.joined(separator: "; ")
            throw AppModelError.profileActivationFailed(
                AppLocalization.format(
                    "One or more profile sessions could not start: %@",
                    detail
                )
            )
        }

        if shouldStartAuxiliary {
            for spec in auxiliarySpecs {
                do {
                    guard case let .running(session)? = await coreFleet.state(
                        for: spec.profileID
                    ) else {
                        throw AppModelError.profileActivationFailed(
                            AppLocalization.format(
                                "%@ did not reach a running state.",
                                profileDisplayName(spec.profileID)
                            )
                        )
                    }
                    let client = try MihomoAPIClient(
                        baseURL: session.endpoint,
                        secret: session.secret
                    )
                    let config = try await client.fetchConfig()
                    guard config.mixedPort == spec.mixedPort else {
                        throw AppModelError.explicitLocalProxyListenerRejected(
                            field: "Mixed",
                            requested: spec.mixedPort,
                            actual: config.mixedPort
                        )
                    }
                    try await localPortProbe.waitUntilProxyProtocols(
                        httpPort: spec.mixedPort,
                        socksPort: spec.mixedPort
                    )
                    try await verifyProfileRouteListenerProtocols(
                        profileID: spec.profileID
                    )
                    let proxies = try await client.fetchProxies()
                    try validateProfileRouteListenerProxyTargets(
                        profileID: spec.profileID,
                        collection: proxies
                    )
                } catch {
                    if !preexistingRunningProfiles.contains(spec.profileID) {
                        _ = await coreFleet.stop(profileID: spec.profileID)
                        auxiliaryCoreStates = await coreFleet.states()
                        auxiliaryLaunchConfigurations[spec.profileID] = nil
                    }
                    throw error
                }
            }

            // Cache only configurations whose exact listener was verified
            // through that profile Core's authenticated controller.
            let knownProfileIDs = Set(profiles.map(\.id))
            auxiliaryLaunchConfigurations = auxiliaryLaunchConfigurations
                .filter { knownProfileIDs.contains($0.key) }
            auxiliaryLaunchConfigurations.merge(
                launchConfigurations,
                uniquingKeysWith: { _, replacement in replacement }
            )
            for spec in auxiliarySpecs {
                verifiedMClashMixedPorts[
                    spec.profileID,
                    default: []
                ].insert(spec.mixedPort)
            }
        }
    }

    private func ensureRuntimePlanCovers(
        activeProfileID: ProfileID,
        rules: [CaptureRule]
    ) async throws {
        guard let store = profileRuntimePlanStore else {
            throw AppModelError.profileStoreUnavailable
        }
        var candidate = profileRuntimePlan
        var required = Set<ProfileID>()
        for rule in rules where rule.enabled {
            guard case let .mihomo(route) = rule.action,
                  let routingProfileID = route.routingProfileID else { continue }
            let profileID = ProfileID(rawValue: routingProfileID.uuid)
            guard profiles.contains(where: { $0.id == profileID }) else {
                throw AppModelError.appRoutingProfileUnavailable(
                    routingProfileID.description
                )
            }
            required.insert(profileID)
        }

        var usedPorts = Set(
            candidate.sessions.map(\.mixedPort)
                + [candidate.defaultMixedPort]
                + candidate.routeListeners.map(\.port)
        )
        if !candidate.sessions.contains(where: { $0.profileID == activeProfileID }) {
            let port = try await preferredMixedPort(
                for: activeProfileID,
                excluding: usedPorts
            )
            usedPorts.insert(port)
            candidate.sessions.append(ProfileSessionSpec(
                profileID: activeProfileID,
                enabled: false,
                mixedPort: port
            ))
        }
        for profileID in required {
            if let index = candidate.sessions.firstIndex(where: {
                $0.profileID == profileID
            }) {
                if !candidate.sessions[index].enabled {
                    throw AppModelError.profileMixedPortDisabled(
                        profileDisplayName(profileID)
                    )
                }
            } else {
                throw AppModelError.profileMixedPortDisabled(
                    profileDisplayName(profileID)
                )
            }
        }
        candidate.primaryProfileID = activeProfileID
        try ProfileRuntimePlanValidator().validate(candidate)
        if candidate != profileRuntimePlan {
            try await store.save(candidate)
            profileRuntimePlan = candidate
        }
    }

    private func persistAuxiliaryRuntimeConfiguration(
        _ data: Data,
        profileID: ProfileID,
        destinationURL: URL
    ) async throws -> Bool {
        if let existing = try? Data(contentsOf: destinationURL),
           existing == data {
            return false
        }
        guard let profileLayout else {
            throw AppModelError.profileStoreUnavailable
        }
        try profileLayout.createRuntimeDirectories(for: profileID)
        let replacer = AtomicFileReplacer()
        let stagedURL = try await replacer.stage(
            data: data,
            in: profileLayout.runtimeStagingDirectory(for: profileID),
            preferredName: "config.yaml"
        )
        do {
            try await makeProfileValidator().validate(configurationAt: stagedURL)
            let receipt = try await replacer.replace(
                destinationURL: destinationURL,
                withStagedFile: stagedURL
            )
            try await replacer.commit(receipt)
            return true
        } catch {
            try? FileManager.default.removeItem(at: stagedURL)
            throw error
        }
    }

    /// Replaces a running Mihomo configuration through its authenticated
    /// controller without stopping the process. The runtime file keeps an
    /// uncommitted atomic backup until the controller accepts the payload; any
    /// failure restores both disk and the previous in-process configuration.
    private func hotReloadRuntimeConfiguration(
        _ data: Data,
        destinationURL: URL,
        stagingDirectory: URL,
        client: MihomoAPIClient,
        verification: () async throws -> Void = {}
    ) async throws -> Bool {
        let previousData = try Data(contentsOf: destinationURL)
        guard previousData != data else { return false }
        guard let payload = String(data: data, encoding: .utf8),
              let previousPayload = String(data: previousData, encoding: .utf8)
        else {
            throw AppModelError.profileActivationFailed(
                AppLocalization.string(
                    "The generated Mihomo configuration is not valid UTF-8."
                )
            )
        }

        let replacer = AtomicFileReplacer()
        let stagedURL = try await replacer.stage(
            data: data,
            in: stagingDirectory,
            preferredName: "config.yaml"
        )
        do {
            try await makeProfileValidator().validate(configurationAt: stagedURL)
        } catch {
            try? FileManager.default.removeItem(at: stagedURL)
            throw error
        }

        let receipt = try await replacer.replace(
            destinationURL: destinationURL,
            withStagedFile: stagedURL
        )
        do {
            try await client.reloadConfig(payload: payload, force: false)
            try await verification()
            try await replacer.commit(receipt)
            return true
        } catch {
            let updateError = error
            var rollbackFailures: [String] = []
            do {
                try await replacer.rollback(receipt)
            } catch {
                rollbackFailures.append(
                    AppLocalization.format(
                        "runtime file: %@",
                        error.localizedDescription
                    )
                )
            }
            do {
                try await client.reloadConfig(
                    payload: previousPayload,
                    force: false
                )
                _ = try await client.fetchConfig()
            } catch {
                rollbackFailures.append(
                    AppLocalization.format(
                        "Mihomo controller: %@",
                        error.localizedDescription
                    )
                )
            }
            if !rollbackFailures.isEmpty {
                throw NetworkCaptureTransactionFailure(
                    updateReason: updateError.localizedDescription,
                    rollbackReason: rollbackFailures.joined(separator: "; ")
                )
            }
            throw updateError
        }
    }

    private func hotReloadActiveProfileRoutingConfigurationIfNeeded(
        profileID: ProfileID
    ) async throws {
        guard let profileStore, let apiClient else {
            throw AppModelError.profileStoreUnavailable
        }
        let composer = RuntimeConfigurationComposer()
        let sourceData: Data
        if unifiedConfigurationEnabled {
            guard let compiledConfiguration else {
                throw AppModelError.profileStoreUnavailable
            }
            sourceData = compiledConfiguration.yaml
        } else {
            sourceData = try await profileStore.configurationData(for: profileID)
        }
        // A compiled unified document is already a blank, MClash-owned YAML
        // document. Sanitizing it as if it were an imported source would
        // remove the named HTTP/SOCKS listeners on every live rule update.
        let managedSourceData: Data
        if unifiedConfigurationEnabled {
            managedSourceData = sourceData
        } else {
            managedSourceData = try composer.sanitizingForManagedSession(sourceData)
        }
        let runtimeData = try composer.applying(
            effectiveRuntimeOverrides(for: profileID),
            to: managedSourceData,
            networkExtensionListener: activeNetworkExtensionMihomoListener,
            profileMixedListener: unifiedConfigurationEnabled
                ? nil
                : activeProfileDedicatedMixedListener,
            routeListeners: profileRouteListeners(for: profileID),
            allowedOutboundProxyNames: unifiedConfigurationEnabled
                ? unifiedRuntimeProxyNames()
                : nil
        )
        _ = try await hotReloadRuntimeConfiguration(
            runtimeData,
            destinationURL: profileStore.layout.runtimeConfigurationURL,
            stagingDirectory: profileStore.layout.runtimeStagingDirectory,
            client: apiClient,
            verification: {
                _ = try await apiClient.fetchConfig()
                if let listener = self.activeNetworkExtensionMihomoListener,
                   let authentication = listener.authentication {
                    try await self.localPortProbe
                        .waitUntilAuthenticatedSOCKS5Proxy(
                            ports: Set(
                                listener.routeListeners.map { Int($0.port) }
                            ),
                            authentication: authentication
                        )
                }
            }
        )
    }

    private func availableTCPPort(excluding ports: Set<Int>) throws -> Int {
        for _ in 0..<64 {
            let port = try localPortProbe.availableTCPPort()
            if !ports.contains(port) { return port }
        }
        throw AppModelError.localProxyPortsUnavailable
    }

    private func secureRandomString() throws -> String {
        var randomBytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(
            kSecRandomDefault,
            randomBytes.count,
            &randomBytes
        )
        guard status == errSecSuccess else {
            throw AppModelError.secureRandomGenerationFailed(status)
        }
        return Data(randomBytes).base64EncodedString()
    }

    private func reusableNetworkExtensionMihomoListener(
        routes requestedRoutes: Set<MihomoRoute>,
        includesLegacyProfileRules: Bool,
        existing: NetworkExtensionMihomoListenerConfiguration?,
        excluding excludedPorts: Set<Int>
    ) -> NetworkExtensionMihomoListenerConfiguration? {
        guard let existing = compatibleNetworkExtensionMihomoListener(
            includesLegacyProfileRules: includesLegacyProfileRules,
            existing: existing,
            excluding: excludedPorts
        ) else { return nil }
        let availableRoutes = Set(existing.routeListeners.map(\.route))
        var requiredRoutes = requestedRoutes
        if includesLegacyProfileRules {
            requiredRoutes.insert(.profileRules)
        }
        guard requiredRoutes.isSubset(of: availableRoutes) else {
            return nil
        }
        return existing
    }

    private func compatibleNetworkExtensionMihomoListener(
        includesLegacyProfileRules: Bool,
        existing: NetworkExtensionMihomoListenerConfiguration?,
        excluding excludedPorts: Set<Int>
    ) -> NetworkExtensionMihomoListenerConfiguration? {
        guard let existing else { return nil }
        let existingPorts = existing.routeListeners.map { Int($0.port) }
        guard existing.includesLegacyProfileRules == includesLegacyProfileRules,
              Set(existingPorts).count == existingPorts.count,
              existingPorts.allSatisfy({ !excludedPorts.contains($0) })
        else { return nil }
        return existing
    }

    private func unifiedRuntimeProxyNames() -> Set<String> {
        let workspace = configurationDocument.currentWorkspace
        var names = Set<String>(ConfigurationBuiltInPolicy.allCases.map(\.rawValue))
        for group in configurationDocument.proxyGroups where
            group.enabled && workspace?.proxyGroupIDs.contains(group.id) == true {
            names.insert(group.name)
        }
        return names
    }

    private func unifiedRuntimeRouteIsValid(
        _ route: MihomoRoute,
        proxyNames: Set<String>
    ) -> Bool {
        switch route.profileRoute {
        case .rules, .global:
            return true
        case let .group(name):
            return proxyNames.contains(name)
        }
    }

    private func expandNetworkExtensionMihomoListener(
        routes requestedRoutes: Set<MihomoRoute>,
        includesLegacyProfileRules: Bool,
        existing: NetworkExtensionMihomoListenerConfiguration,
        ports: [Int]
    ) throws -> NetworkExtensionMihomoListenerConfiguration {
        var requiredRoutes = requestedRoutes
        if includesLegacyProfileRules {
            requiredRoutes.insert(.profileRules)
        }
        guard requiredRoutes.count <= Self.maximumDedicatedMihomoRoutes
                + (includesLegacyProfileRules ? 1 : 0)
        else {
            throw AppModelError.tooManyNetworkCaptureRoutes(
                actual: requestedRoutes.count,
                maximum: Self.maximumDedicatedMihomoRoutes
            )
        }

        var routePorts = Dictionary(
            uniqueKeysWithValues: existing.routeListeners.map {
                ($0.route, Int($0.port))
            }
        )
        let missingRoutes = requiredRoutes
            .subtracting(routePorts.keys)
            .sorted {
                Self.mihomoRouteSortKey($0) < Self.mihomoRouteSortKey($1)
            }
        guard missingRoutes.count == ports.count,
              Set(ports).count == ports.count,
              ports.allSatisfy({ (1...65_535).contains($0) })
        else {
            throw AppModelError.localProxyPortsUnavailable
        }
        for (route, port) in zip(missingRoutes, ports) {
            routePorts[route] = port
        }
        return try NetworkExtensionMihomoListenerConfiguration(
            port: Int(existing.port),
            authentication: existing.authentication,
            routePorts: routePorts,
            includesLegacyProfileRules: includesLegacyProfileRules
        )
    }

    private func makeNetworkExtensionMihomoListener(
        routes requestedRoutes: Set<MihomoRoute>,
        includesLegacyProfileRules: Bool,
        ports: [Int]
    ) throws -> NetworkExtensionMihomoListenerConfiguration {
        guard requestedRoutes.count <= Self.maximumDedicatedMihomoRoutes else {
            throw AppModelError.tooManyNetworkCaptureRoutes(
                actual: requestedRoutes.count,
                maximum: Self.maximumDedicatedMihomoRoutes
            )
        }
        let expectedPortCount = requestedRoutes.count
            + (includesLegacyProfileRules ? 1 : 0)
        guard ports.count == expectedPortCount,
              Set(ports).count == ports.count,
              ports.allSatisfy({ (1...65_535).contains($0) })
        else {
            throw AppModelError.localProxyPortsUnavailable
        }

        let authentication = try NetworkExtensionMihomoAuthentication(
            username: "mclash-network-extension",
            password: try secureRandomString()
        )
        let sortedRoutes = requestedRoutes.sorted {
            Self.mihomoRouteSortKey($0) < Self.mihomoRouteSortKey($1)
        }
        var routePorts: [MihomoRoute: Int] = [:]
        let routePortValues = includesLegacyProfileRules
            ? ports.dropFirst()
            : ports[...]
        for (route, port) in zip(sortedRoutes, routePortValues) {
            routePorts[route] = port
        }
        return try NetworkExtensionMihomoListenerConfiguration(
            port: ports[0],
            authentication: authentication,
            routePorts: routePorts,
            includesLegacyProfileRules: includesLegacyProfileRules
        )
    }

    private static func mihomoRouteSortKey(_ route: MihomoRoute) -> String {
        route.stableSortKey
    }

    private func refreshActiveProfileListenerPorts() async {
        guard let activeProfileID, let profileStore else {
            activeProfileListenerPorts = RuntimePortOverrides()
            return
        }
        do {
            let data = try await profileStore.configurationData(for: activeProfileID)
            activeProfileListenerPorts = try RuntimeConfigurationComposer().listenerPorts(in: data)
        } catch {
            activeProfileListenerPorts = RuntimePortOverrides()
            appendSupervisorLog("Could not read the active profile's listener ports: \(error.localizedDescription)")
        }
    }

    private var mixedListenerConfiguredSource: LocalListenerSource {
        if runtimeOverrides.ports.mixedPort != nil {
            return .override
        }
        let plannedPort = profileRuntimePlan.defaultMixedPort
        guard let profilePort = positivePort(activeProfileListenerPorts.mixedPort ?? 0) else {
            return .managedFallback
        }
        return profilePort == plannedPort ? .profile : .override
    }

    private func setConnectionDesiredOnLaunch(_ desired: Bool) {
        guard connectionDesiredOnLaunch != desired else { return }
        connectionDesiredOnLaunch = desired
        preferenceDefaults.set(desired, forKey: Self.connectionDesiredOnLaunchKey)
    }

    private var hasSystemProxySnapshot: Bool {
        guard let profileLayout else { return false }
        return FileManager.default.fileExists(
            atPath: systemProxySnapshotURL(layout: profileLayout).path
        )
    }

    static let autoConnectOnLaunchKey = "network.autoConnectOnLaunch"
    static let connectionDesiredOnLaunchKey = "network.connectionDesiredOnLaunch"
    static let autoEnableSystemProxyKey = "network.autoEnableSystemProxy"
    static let menuBarDisplayStyleKey = "application.menuBarDisplayStyle"
    static let pinnedQuickRouteNamesKey = "application.menuBarPinnedQuickRoutes"
    static let closeConnectionsOnRoutingChangeKey = "network.closeConnectionsOnRoutingChange"
    static let trafficHistoryPersistenceChoiceKey = "traffic.history.persistenceChoice"
    static let notificationsEnabledKey = "application.notificationsEnabled"
    static let openAtLoginSilentlyKey = "application.openAtLoginSilently"
    static let lightweightModeKey = "application.lightweightMode"
    static let unifiedConfigurationEnabledKey = "configuration.unifiedEnabled"
    static let unifiedConfigurationMigrationVersionKey =
        "configuration.unifiedMigrationVersion"
    static let unifiedConfigurationMigrationVersion = 1
    static let systemProxyGuardFailureThreshold = 3
    static let appRoutingProviderFailureThreshold = 3
    static let appRoutingProviderStatusCheckInterval = 5
    static let networkExtensionPreferencesCheckInterval: Duration = .seconds(60)
    static let maximumDedicatedMihomoRoutes = 64
    private static let trafficHistoryPruneInterval: TimeInterval = 24 * 60 * 60

    nonisolated private static func saturatingAdd(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
        let (value, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? .max : value
    }
}

private actor OneShotContinuation<Value: Sendable> {
    private var continuation: CheckedContinuation<Value, Never>?

    init(_ continuation: CheckedContinuation<Value, Never>) {
        self.continuation = continuation
    }

    func resume(returning value: Value) {
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(returning: value)
    }
}

private extension AppModel.Operation {
    var serializesNetworkState: Bool {
        switch self {
        case .connection,
             .importProfile,
             .addRemoteProfile,
             .updateProfile,
             .activateProfile,
             .refreshProfile,
             .refreshAllProfiles,
             .removeProfile,
             .changeRuntimeSettings,
             .changeSystemProxySettings,
             .changeApplicationSettings,
             .exportBackup,
             .restoreBackup,
             .changeSystemProxy,
             .changeNetworkCapture,
             .recoverNetworkEnvironment:
            true
        case .changeMode,
             .selectProxy,
             .clearProxyOverride,
             .measureDelay,
             .measureGroupDelay,
             .refreshProfileProxyWorkspace,
             .changeProfileMode,
             .selectProfileProxy,
             .clearProfileProxyOverride,
             .measureProfileProxyDelay,
             .measureProfileGroupDelay,
             .refreshRules,
             .refreshProviders,
             .updateProxyProvider,
             .healthCheckProxyProvider,
             .updateRuleProvider,
             .closeConnection,
             .closeAllConnections:
            false
        }
    }

    var isCoreBound: Bool {
        switch self {
        case .changeMode,
             .selectProxy,
             .clearProxyOverride,
             .measureDelay,
             .measureGroupDelay,
             .refreshProfileProxyWorkspace,
             .changeProfileMode,
             .selectProfileProxy,
             .clearProfileProxyOverride,
             .measureProfileProxyDelay,
             .measureProfileGroupDelay,
             .refreshRules,
             .refreshProviders,
             .updateProxyProvider,
             .healthCheckProxyProvider,
             .updateRuleProvider,
             .closeConnection,
             .closeAllConnections:
            true
        case .connection,
             .importProfile,
             .addRemoteProfile,
             .updateProfile,
             .activateProfile,
             .refreshProfile,
             .refreshAllProfiles,
             .removeProfile,
             .changeRuntimeSettings,
             .changeSystemProxySettings,
             .changeApplicationSettings,
             .exportBackup,
             .restoreBackup,
             .changeSystemProxy,
             .changeNetworkCapture,
             .recoverNetworkEnvironment:
            false
        }
    }
}

private struct ProxyTopologyInput: Equatable, Sendable {
    let profileStructure: ProfileStructure
    let proxies: [String: ProxyTopologyInputProxy]

    init(collection: MihomoProxyCollection, profileStructure: ProfileStructure) {
        self.profileStructure = profileStructure
        proxies = collection.proxies.mapValues(ProxyTopologyInputProxy.init)
    }
}

private struct ProxyTopologyInputProxy: Equatable, Sendable {
    let type: String
    let members: [String]
    let selected: String?
    let fixed: String?
    let dialerProxy: String?
    let providerName: String?
    let hidden: Bool

    init(proxy: MihomoProxy) {
        type = proxy.type
        members = proxy.all
        selected = Self.nonEmpty(proxy.now)
        fixed = proxy.fixedOverride
        dialerProxy = Self.nonEmpty(proxy.dialerProxy)
        providerName = Self.nonEmpty(proxy.providerName)
        hidden = proxy.hidden
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        return value
    }
}

private extension AppModel.NetworkCaptureState {
    func isActive(revision expectedRevision: UInt64) -> Bool {
        guard case let .on(revision) = self else { return false }
        return revision == expectedRevision
    }
}

private enum AppModelError: LocalizedError {
    case profileStoreUnavailable
    case operationInProgress
    case streamEnded(String)
    case systemProxyRestoreFailed
    case networkCaptureDisableFailed
    case secureRandomGenerationFailed(OSStatus)
    case profileActivationFailed(String)
    case localProxyPortsUnavailable
    case localProxyOverrideRejected(Int)
    case explicitLocalProxyListenersIncomplete
    case explicitLocalProxyListenersUnavailable([Int])
    case explicitLocalProxyListenerRejected(field: String, requested: Int, actual: Int)
    case systemProxyGuardVerificationFailed
    case tooManyNetworkCaptureRoutes(actual: Int, maximum: Int)
    case primaryProfileCannotBeDisabled
    case profileRequiredByAppRouting(String)
    case appRoutingProfileUnavailable(String)
    case profileMixedPortDisabled(String)
    case profileMixedPortUnavailable(String, Int)
    case primaryListenerPortConflict([Int])
    case routeListenerPortUnavailable(String, Int)
    case routeListenerTargetUnavailable(String, String)

    var errorDescription: String? {
        switch self {
        case .profileStoreUnavailable:
            AppLocalization.string("The MClash profile store is unavailable.")
        case .operationInProgress:
            AppLocalization.string("This operation is already in progress.")
        case let .streamEnded(name):
            AppLocalization.format(
                "%@ stream ended unexpectedly.",
                AppLocalization.string(name)
            )
        case .systemProxyRestoreFailed:
            AppLocalization.string(
                "MClash could not restore the previous macOS proxy settings, so the running core was left active."
            )
        case .networkCaptureDisableFailed:
            AppLocalization.string(
                "MClash could not stop Network Extension capture, so the mihomo core was left active."
            )
        case let .secureRandomGenerationFailed(status):
            AppLocalization.format(
                "MClash could not generate private Network Extension credentials (OSStatus %@).",
                String(status)
            )
        case let .profileActivationFailed(message):
            message
        case .localProxyPortsUnavailable:
            AppLocalization.string(
                "The active profile does not expose a usable Mixed proxy port."
            )
        case let .localProxyOverrideRejected(port):
            AppLocalization.format(
                "mihomo did not accept MClash's temporary local proxy port %@.",
                String(port)
            )
        case .explicitLocalProxyListenersIncomplete:
            AppLocalization.string(
                "The requested Mixed proxy port is missing from the runtime configuration."
            )
        case let .explicitLocalProxyListenersUnavailable(ports):
            AppLocalization.format(
                "The requested local proxy listener did not start on %@. Choose available ports and try again.",
                ports.map(String.init).joined(separator: ", ")
            )
        case let .explicitLocalProxyListenerRejected(field, requested, actual):
            AppLocalization.format(
                "mihomo did not apply the requested %@ listener port %@; it reported %@.",
                field,
                String(requested),
                String(actual)
            )
        case .systemProxyGuardVerificationFailed:
            AppLocalization.string(
                "The macOS system proxy still did not match MClash after reapplying it."
            )
        case let .tooManyNetworkCaptureRoutes(actual, maximum):
            AppLocalization.format(
                "App Routing requests %@ distinct Mihomo route targets; the safe maximum is %@.",
                String(actual),
                String(maximum)
            )
        case .primaryProfileCannotBeDisabled:
            AppLocalization.string("The current default profile must remain enabled.")
        case let .profileRequiredByAppRouting(name):
            AppLocalization.format(
                "%@ is still used by an enabled App Routing rule. Change or disable that rule first.",
                name
            )
        case let .appRoutingProfileUnavailable(identifier):
            AppLocalization.format(
                "App Routing targets profile %@, but that profile is no longer available.",
                identifier
            )
        case let .profileMixedPortDisabled(name):
            AppLocalization.format(
                "%@ is selected by App Routing, but its Mixed port is off. Open the Mixed port or choose another profile.",
                name
            )
        case let .profileMixedPortUnavailable(name, port):
            AppLocalization.format(
                "%@ cannot start because Mixed port %@ is already in use.",
                name,
                String(port)
            )
        case let .primaryListenerPortConflict(ports):
            AppLocalization.format(
                "The default profile cannot start because its Redirect, TProxy, DNS, or custom listener conflicts with another Profile session on port %@. Choose distinct ports and try again.",
                ports.map(String.init).joined(separator: ", ")
            )
        case let .routeListenerPortUnavailable(name, port):
            AppLocalization.format(
                "Routing port “%@” cannot start because port %@ is already in use.",
                name,
                String(port)
            )
        case let .routeListenerTargetUnavailable(name, target):
            AppLocalization.format(
                "Routing port “%@” points to “%@”, which is not available in its Profile.",
                name,
                target
            )
        }
    }
}

private struct SystemProxyPreferenceRollbackFailure: LocalizedError {
    let updateReason: String
    let rollbackReason: String

    var errorDescription: String? {
        AppLocalization.format(
            "The new macOS system proxy settings could not be verified, and MClash could not restore the previous settings. Update error: %@ Rollback error: %@",
            updateReason,
            rollbackReason
        )
    }
}

private struct NetworkCaptureTransactionFailure: LocalizedError {
    let updateReason: String
    let rollbackReason: String

    var errorDescription: String? {
        AppLocalization.format(
            "The App Routing change failed and MClash could not completely restore the previous network state. Update error: %@ Recovery error: %@",
            updateReason,
            rollbackReason
        )
    }
}

private struct BackupRestoreTransactionFailure: LocalizedError {
    let updateReason: String
    let rollbackReason: String

    var errorDescription: String? {
        AppLocalization.format(
            "The backup could not be activated and MClash could not completely restore the previous runtime. Restore error: %@ Recovery error: %@",
            updateReason,
            rollbackReason
        )
    }
}

private enum AppRoutingProviderRuntimeError: LocalizedError {
    case stateMismatch(
        expectedRevision: UInt64,
        actualRevision: UInt64,
        running: Bool,
        captureEnabled: Bool,
        providerMessage: String?
    )

    var errorDescription: String? {
        switch self {
        case let .stateMismatch(
            expectedRevision,
            actualRevision,
            running,
            captureEnabled,
            providerMessage
        ):
            if let providerMessage = providerMessage.flatMap({ $0.isEmpty ? nil : $0 }) {
                return AppLocalization.format(
                    "Provider reported running=%@, captureEnabled=%@, revision=%@; expected running=true, captureEnabled=true, revision=%@. Provider message: %@",
                    String(running),
                    String(captureEnabled),
                    String(actualRevision),
                    String(expectedRevision),
                    providerMessage
                )
            }
            return AppLocalization.format(
                "Provider reported running=%@, captureEnabled=%@, revision=%@; expected running=true, captureEnabled=true, revision=%@.",
                String(running),
                String(captureEnabled),
                String(actualRevision),
                String(expectedRevision)
            )
        }
    }
}
