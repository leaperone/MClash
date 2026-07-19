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
            case .traffic: "traffic rate"
            case .connections: "connection"
            case .logs: "log"
            case .proxies: "proxy state"
            case .appRouting: "App Routing activity"
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

        static func resolve(
            mainWindowVisible: Bool,
            menuBarContentVisible: Bool,
            destination: Destination?,
            appRoutingActivityVisible: Bool
        ) -> Self {
            var policy = Self()

            if menuBarContentVisible {
                policy.traffic = true
                policy.connections = true
                policy.proxies = true
            }

            guard mainWindowVisible else { return policy }
            switch destination ?? .overview {
            case .overview:
                policy.traffic = true
                policy.connections = true
                policy.appRoutingActivity = true
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
        case http
        case socks5
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
        case selectProxy(String)
        case clearProxyOverride(String)
        case measureDelay(String)
        case measureGroupDelay(String)
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
        case proxies
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
            case .proxies: "Proxies"
            case .appRouting: "App Routing"
            case .profiles: "Profiles"
            case .rules: "Mihomo Rules"
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
            case .proxies: "point.3.connected.trianglepath.dotted"
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
    private(set) var menuBarContentIsVisible = false
    private(set) var appRoutingActivityViewIsVisible = false
    var coreState: CoreRunState = .stopped
    var activeConfigURL: URL?
    var logs: [CoreLogLine] = []
    var errorMessage: String?
    var profiles: [ProfileMetadata] = []
    private(set) var profileBatchUpdateReceipt: ProfileBatchUpdateReceipt?
    var activeProfileID: ProfileID?
    var runtimeConfig: MihomoConfig?
    private(set) var runtimeOverrides: RuntimeOverrides = .empty
    private(set) var activeProfileListenerPorts = RuntimePortOverrides()
    private(set) var runtimeSettingsApplyState: RuntimeSettingsApplyState = .idle
    var proxyGroups: [MihomoProxy] = []
    var proxiesByName: [String: MihomoProxy] = [:]
    var proxyTopology: ProxyTopology = .empty
    var proxySelectionPaths: [String: ProxySelectionPath] = [:]
    var proxyDelays: [String: Int] = [:]
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
    private(set) var systemProxyPreferences: SystemProxyPreferences = .defaults
    private(set) var networkCaptureState: NetworkCaptureState = .off
    private(set) var networkCapturePreferences = NetworkCapturePreferences.disabled()
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
    private(set) var notificationsEnabled = false
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
    var autoEnableSystemProxy: Bool {
        didSet {
            preferenceDefaults.set(autoEnableSystemProxy, forKey: Self.autoEnableSystemProxyKey)
        }
    }
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
    private let binaryLocator: CoreBinaryLocator
    private let secretStore: any CoreSecretProviding
    private let profileStore: ProfileStore?
    private let profileLayout: ProfileDirectoryLayout?
    private let runtimeOverrideCoordinator: RuntimeOverrideActivationCoordinator?
    private let systemProxyPreferencesStore: SystemProxyPreferencesStore?
    private let networkCaptureConfigurationStore: NetworkCaptureConfigurationStore?
    private let networkExtensionControl: any NetworkExtensionControlling
    private let systemProxyManager: SystemProxyManager
    private let localPortProbe: LocalPortProbe
    private let geoDataInstaller: BundledGeoDataInstaller
    private let preferenceDefaults: UserDefaults
    private let profileBackupService = ProfileBackupService()
    private let notificationCenter = AppNotificationCenter()
    private var managedMixedPort: Int?
    private var networkExtensionMihomoListener: NetworkExtensionMihomoListenerConfiguration?
    private var rulesUseGlobalProxy = false
    private var connectionsUseGlobalProxy = false
    private var apiClient: MihomoAPIClient?
    private var activeControllerEndpoint: URL?
    private var controllerSetupOperation: (id: UUID, endpoint: URL, task: Task<Void, Never>)?
    private var eventTask: Task<Void, Never>?
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
    private var contextualProxyDelays: [ProxyDelayContextKey: Int] = [:]
    private var proxyProfileStructure: ProfileStructure = .empty
    private var trafficAttribution = TrafficAttribution()
    private var persistentTrafficHistoryStore: TrafficHistoryStore?
    private var trafficHistoryPersistTask: Task<Void, Never>?
    private var trafficHistoryPersistGeneration: UInt64 = 0
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
    private var appRoutingActivityTask: Task<Void, Never>?
    private var appRoutingMonitorGeneration: UInt64 = 0
    private var dnsProxyRuntimeTask: Task<Void, Never>?
    private var dnsProxyMonitorGeneration: UInt64 = 0
    private var appRoutingActivityCursor: UInt64 = 0
    private var appRoutingActivitiesByIdentifier: [UUID: AppRoutingActivity] = [:]
    private var appRoutingTrafficRateTracker = AppRoutingTrafficRateTracker()
    private(set) var appRoutingProviderStatusFailureCount = 0
    private(set) var appRoutingProviderLastVerifiedAt: Date?
    private(set) var preparationInProgress = false
    private var shutdownInProgress = false
    private var startupPreparationErrorMessage: String?

    init(
        supervisor: CoreSupervisor = CoreSupervisor(),
        binaryLocator: CoreBinaryLocator = CoreBinaryLocator(),
        secretStore: any CoreSecretProviding = EphemeralCoreSecretProvider(),
        systemProxyManager: SystemProxyManager = SystemProxyManager(),
        localPortProbe: LocalPortProbe = LocalPortProbe(),
        profileDirectoryLayout: ProfileDirectoryLayout? = nil,
        profileStoreOverride: ProfileStore? = nil,
        geoDataInstaller: BundledGeoDataInstaller = .applicationBundle(),
        preferenceDefaults: UserDefaults = .standard,
        networkExtensionControl: any NetworkExtensionControlling = NetworkExtensionControlService.live()
    ) {
        self.supervisor = supervisor
        self.binaryLocator = binaryLocator
        self.secretStore = secretStore
        self.systemProxyManager = systemProxyManager
        self.localPortProbe = localPortProbe
        self.geoDataInstaller = geoDataInstaller
        self.preferenceDefaults = preferenceDefaults
        self.networkExtensionControl = networkExtensionControl
        if preferenceDefaults.object(forKey: Self.trafficHistoryPersistenceChoiceKey) == nil {
            trafficHistoryPersistenceChoice = .undecided
        } else {
            trafficHistoryPersistenceChoice = TrafficHistoryPersistenceChoice(
                rawValue: preferenceDefaults.integer(
                    forKey: Self.trafficHistoryPersistenceChoiceKey
                )
            ) ?? .undecided
        }
        if preferenceDefaults.object(forKey: Self.autoConnectOnLaunchKey) == nil {
            autoConnectOnLaunch = true
        } else {
            autoConnectOnLaunch = preferenceDefaults.bool(forKey: Self.autoConnectOnLaunchKey)
        }
        if preferenceDefaults.object(forKey: Self.autoEnableSystemProxyKey) == nil {
            autoEnableSystemProxy = true
        } else {
            autoEnableSystemProxy = preferenceDefaults.bool(forKey: Self.autoEnableSystemProxyKey)
        }
        if preferenceDefaults.object(forKey: Self.closeConnectionsOnRoutingChangeKey) == nil {
            closeConnectionsOnRoutingChange = true
        } else {
            closeConnectionsOnRoutingChange = preferenceDefaults.bool(
                forKey: Self.closeConnectionsOnRoutingChangeKey
            )
        }
        notificationsEnabled = preferenceDefaults.bool(forKey: Self.notificationsEnabledKey)
        launchAtLogin = LoginItemManager().isEnabled

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
                        recoverySuggestion: "Restore access to the user Application Support folder, then relaunch MClash."
                    )
                )
            }
        }

        profileLayout = layout
        if let layout {
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
                            recoverySuggestion: "Restore read and write access to \(layout.profilesDirectory.path), then relaunch MClash."
                        )
                    )
                }
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
                        recoverySuggestion: "Restore read and write access to the MClash Settings folder, then relaunch MClash."
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
                        recoverySuggestion: "Restore read and write access to the MClash Settings folder, then relaunch MClash."
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
                        recoverySuggestion: "Restore read and write access to the MClash Settings folder, then relaunch MClash."
                    )
                )
            }
        } else {
            profileStore = nil
            runtimeOverrideCoordinator = nil
            systemProxyPreferencesStore = nil
            networkCaptureConfigurationStore = nil
        }
        storageInitializationFailures = initializationFailures

        eventTask = Task { [weak self, events = supervisor.events] in
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

        do {
            try LoginItemManager().migrateLegacyRegistrationIfNeeded()
            launchAtLogin = LoginItemManager().isEnabled
        } catch {
            appendSupervisorLog(
                "Launch at Login could not be migrated to background mode: \(error.localizedDescription)"
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
                            recoverySuggestion: "Restore or remove the invalid runtime settings document, then relaunch MClash."
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
                            recoverySuggestion: "Restore or remove the invalid system proxy settings document, then relaunch MClash."
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
                            recoverySuggestion: "Restore or remove the invalid App Routing settings document, then relaunch MClash."
                        )
                        throw error
                    }
                    if networkCapturePreferences.enabled {
                        networkExtensionMihomoListener = try makeNetworkExtensionMihomoListener(
                            for: networkCapturePreferences.snapshot.rules
                        )
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
                        recoverySuggestion: "Restore read access to the Profiles and State folders, then relaunch MClash."
                    )
                    throw error
                }
                await refreshActiveProfileListenerPorts()
                if let activeProfileID {
                    if runtimeOverrideCoordinator != nil {
                        let activation = try await activateStoredProfile(
                            activeProfileID,
                            validator: try makeProfileValidator()
                        )
                        activeConfigURL = activation.configurationURL
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
        } catch is CancellationError {
            return
        } catch {
            let message = error.localizedDescription
            startupPreparationErrorMessage = message
            errorMessage = message
            appendSupervisorLog("Startup preparation failed: \(message)")
        }
    }

    private func connectActiveProfileAtLaunchIfAvailable() async {
        guard autoConnectOnLaunch,
              let activeProfileID,
              profiles.contains(where: { $0.id == activeProfileID }),
              let activeConfigURL,
              FileManager.default.fileExists(atPath: activeConfigURL.path),
              !systemProxyRecoveryRequired,
              !shutdownInProgress,
              !Task.isCancelled,
              !isConnected,
              !isBusy else {
            return
        }

        let connected = await performConnect()
        guard !shutdownInProgress, !Task.isCancelled else { return }
        if connected, autoEnableSystemProxy {
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
        case .stopped: "Disconnected"
        case .validating: "Checking configuration"
        case .starting: "Connecting"
        case .running: "Connected"
        case .stopping: "Disconnecting"
        case .failed: "Needs attention"
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
            mainWindowVisible: mainWindowIsVisible,
            menuBarContentVisible: menuBarContentIsVisible,
            destination: selection,
            appRoutingActivityVisible: appRoutingActivityViewIsVisible
        )
    }

    func setMainWindowVisible(_ isVisible: Bool) {
        guard mainWindowIsVisible != isVisible else { return }
        mainWindowIsVisible = isVisible
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
        guard let runtimeConfig else { return nil }
        return positivePort(runtimeConfig.port)
    }

    var localSOCKSListenerPort: Int? {
        guard let runtimeConfig else { return nil }
        return positivePort(runtimeConfig.socksPort)
    }

    var localMixedListenerPort: Int? {
        guard let runtimeConfig else { return nil }
        return managedMixedPort ?? positivePort(runtimeConfig.mixedPort)
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
        [
            listenerEndpoint(
                kind: .http,
                port: localHTTPListenerPort,
                isOverridden: runtimeOverrides.ports.port != nil
            ),
            listenerEndpoint(
                kind: .socks5,
                port: localSOCKSListenerPort,
                isOverridden: runtimeOverrides.ports.socksPort != nil
            ),
            localMixedListenerPort.map {
                LocalListenerEndpoint(
                    kind: .mixed,
                    host: "127.0.0.1",
                    port: $0,
                    source: managedMixedPort == nil ? mixedListenerConfiguredSource : .managedFallback
                )
            },
        ]
        .compactMap { $0 }
    }

    /// Effective HTTP endpoint used when configuring macOS. A mixed listener
    /// is a protocol-compatible fallback, while a managed mixed listener takes
    /// precedence because it was created after configured listeners failed.
    var localHTTPProxyPort: Int? {
        managedMixedPort ?? localHTTPListenerPort ?? localMixedListenerPort
    }

    /// Effective SOCKS endpoint used when configuring macOS. See
    /// `localHTTPProxyPort` for the fallback semantics.
    var localSOCKSProxyPort: Int? {
        managedMixedPort ?? localSOCKSListenerPort ?? localMixedListenerPort
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

    func importProfile() async {
        guard begin(.importProfile) else { return }
        defer { end(.importProfile) }

        guard let profileStore else {
            errorMessage = "The profile store could not be initialized."
            return
        }

        let panel = NSOpenPanel()
        panel.title = "Import a mihomo profile"
        panel.prompt = "Import"
        panel.allowedContentTypes = [.yaml]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false

        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            let profile = try await profileStore.importProfile(from: url)
            profiles = try await profileStore.profiles()
            try await performActivateProfile(profile.id)
        } catch {
            recordOperationFailure(error, context: "Profile import")
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
                "The imported profile must be between 1 byte and \(MClashAutomationProtocol.maximumInlineProfileSize) bytes."
            )
        }

        let safeName = URL(fileURLWithPath: suggestedFileName).lastPathComponent
        guard !safeName.isEmpty, safeName.utf8.count <= 128,
              safeName.lowercased().hasSuffix(".yaml") || safeName.lowercased().hasSuffix(".yml") else {
            throw AppModelError.profileActivationFailed(
                "The imported profile filename must end in .yaml or .yml."
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
            if activeProfileID == createdProfileID {
                try await profileStore.setActiveProfile(previousProfileID)
                activeProfileID = previousProfileID
                activeConfigURL = previousProfileID.map {
                    profileLayout.configurationURL(for: $0)
                }
                await refreshActiveProfileListenerPorts()
            }
            try await profileStore.removeProfile(createdProfileID)
            profiles = try await profileStore.profiles()
        } catch {
            let message = "\(activationError.localizedDescription) Rolling back the newly created profile failed: \(error.localizedDescription)"
            throw AppModelError.profileActivationFailed(message)
        }
        throw activationError
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
            selection = .profiles
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
            selection = .profiles
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
        try LoginItemManager().setEnabled(enabled)
        launchAtLogin = LoginItemManager().isEnabled
    }

    func setNotificationsEnabled(_ enabled: Bool) async {
        guard begin(.changeApplicationSettings) else { return }
        defer { end(.changeApplicationSettings) }
        if enabled {
            do {
                notificationsEnabled = try await notificationCenter.requestAuthorization()
                if !notificationsEnabled {
                    errorMessage = "macOS notification permission was not granted."
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
            errorMessage = "The application state directory is unavailable."
            return false
        }

        let panel = NSSavePanel()
        panel.title = "Export MClash Backup"
        panel.prompt = "Export"
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
            errorMessage = "The application state directory is unavailable."
            return false
        }

        let panel = NSOpenPanel()
        panel.title = "Restore MClash Backup"
        panel.prompt = "Restore"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let backupURL = panel.url else { return nil }

        let shouldReconnect = isConnected || isBusy
        let shouldRestoreSystemProxy = systemProxyEnabled
        if shouldReconnect, !(await performDisconnect()) { return false }

        do {
            _ = try await profileBackupService.restoreBackup(
                from: backupURL,
                to: profileLayout
            )
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
            profiles = try await profileStore.profiles()
            activeProfileID = try await profileStore.activeProfileID()
            await refreshActiveProfileListenerPorts()
            activeConfigURL = nil
            if let activeProfileID {
                let activation = try await activateStoredProfile(
                    activeProfileID,
                    validator: try makeProfileValidator()
                )
                activeConfigURL = activation.configurationURL
            }
            if shouldReconnect, activeConfigURL != nil {
                let connected = await performConnect()
                if connected, shouldRestoreSystemProxy {
                    await performEnableSystemProxy()
                }
            }
            errorMessage = nil
            return true
        } catch {
            recordOperationFailure(error, context: "Backup restore")
            if shouldReconnect, activeConfigURL != nil {
                _ = await performConnect()
                if isConnected, shouldRestoreSystemProxy {
                    await performEnableSystemProxy()
                }
            }
            return false
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

        // Validate the target before interrupting a healthy current session.
        let validator = try makeProfileValidator()
        try await validator.validate(configurationAt: profileLayout.configurationURL(for: id))

        let shouldReconnect = isConnected || isBusy
        let shouldRestoreSystemProxy = systemProxyEnabled
        if shouldReconnect {
            guard await performDisconnect() else {
                throw AppModelError.systemProxyRestoreFailed
            }
        }

        let previousProfileID = activeProfileID
        let activation: RuntimeConfigurationActivation
        do {
            activation = try await activateStoredProfile(
                id,
                validator: validator
            )
        } catch {
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

            let activationFailure = errorMessage ?? "The new profile could not be started."
            guard await stopCore() else {
                let stopFailure = errorMessage
                    ?? "The candidate proxy core could not be confirmed stopped."
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
                        ? "The previous profile was restored."
                        : "The previous profile also could not be restarted."
                    errorMessage = "\(activationFailure) \(restoration)"
                } catch {
                    errorMessage = "\(activationFailure) Restoring the previous profile failed: \(error.localizedDescription)"
                }
                appendSupervisorLog(errorMessage ?? activationFailure)
            } else {
                errorMessage = activationFailure
            }
            throw AppModelError.profileActivationFailed(errorMessage ?? activationFailure)
        }
    }

    private func activateStoredProfile(
        _ id: ProfileID,
        validator: any ProfileValidating
    ) async throws -> RuntimeConfigurationActivation {
        guard let profileStore else {
            throw AppModelError.profileStoreUnavailable
        }
        if let runtimeOverrideCoordinator {
            return try await runtimeOverrideCoordinator.activateProfile(
                id,
                networkExtensionListener: activeNetworkExtensionMihomoListener,
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
        guard let profileStore, let runtimeOverrideCoordinator else {
            throw AppModelError.profileStoreUnavailable
        }
        return try await runtimeOverrideCoordinator.activateProfile(
            id,
            overrides: overrides,
            networkExtensionListener: activeNetworkExtensionMihomoListener,
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

        guard let runtimeOverrideCoordinator, let profileStore else {
            throw AppModelError.profileStoreUnavailable
        }

        let previousOverrides = runtimeOverrides
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

        let validator: any ProfileValidating
        do {
            runtimeSettingsApplyState = .validating
            validator = try makeProfileValidator()
            try await runtimeOverrideCoordinator.validateProfile(
                activeProfileID,
                overrides: overrides,
                networkExtensionListener: activeNetworkExtensionMihomoListener,
                in: profileStore,
                validator: validator
            )
        } catch {
            runtimeSettingsApplyState = .failed(error.localizedDescription)
            throw error
        }

        let shouldRestart = isConnected || isBusy
        let shouldRestoreSystemProxy = systemProxyEnabled
        if shouldRestart {
            runtimeSettingsApplyState = .restarting
            guard await performDisconnect() else {
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
                        errorMessage ?? "The updated runtime configuration could not be started."
                    )
                }
            }

            runtimeSettingsApplyState = .saving
            try await runtimeOverrideCoordinator.save(overrides)

            if shouldRestart, shouldRestoreSystemProxy {
                await performEnableSystemProxy()
                guard systemProxyState == .on else {
                    throw AppModelError.profileActivationFailed(
                        errorMessage ?? "The macOS system proxy could not be restored after restarting the core."
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
            let primaryMessage = error.localizedDescription
            let restorationFailures = await Task { @MainActor [weak self] in
                guard let self else { return ["MClash closed before rollback completed."] }
                return await self.rollbackRuntimeOverrides(
                    previousOverrides,
                    activeProfileID: activeProfileID,
                    shouldReconnect: shouldRestart,
                    shouldRestoreSystemProxy: shouldRestoreSystemProxy
                )
            }.value
            let restorationMessage = restorationFailures.isEmpty
                ? "The previous runtime settings were restored."
                : "Restoring the previous runtime settings failed: "
                    + restorationFailures.joined(separator: " ")
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

    private func rollbackRuntimeOverrides(
        _ previousOverrides: RuntimeOverrides,
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
            failures.append("The previous override document could not be saved: \(error.localizedDescription)")
        }
        runtimeOverrides = previousOverrides

        if isConnected || isBusy || hasSystemProxySnapshot {
            let disconnected = await performDisconnect()
            if !disconnected {
                failures.append(
                    "The candidate core could not be stopped safely: "
                        + (errorMessage ?? "No additional error was reported.")
                )
                return failures
            }
        } else {
            guard await stopCore() else {
                failures.append(
                    "The candidate core could not be stopped safely: "
                        + (errorMessage ?? "No additional error was reported.")
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
            failures.append("The previous runtime configuration could not be activated: \(error.localizedDescription)")
            return failures
        }

        if shouldReconnect {
            guard await performConnect() else {
                failures.append(
                    "The previous core session could not be restarted: "
                        + (errorMessage ?? "No additional error was reported.")
                )
                return failures
            }
        }

        if shouldReconnect, shouldRestoreSystemProxy {
            await performEnableSystemProxy()
            if systemProxyState != .on {
                failures.append(
                    "The macOS system proxy could not be re-enabled: "
                        + (errorMessage ?? "No additional error was reported.")
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
        if activeProfileID == id {
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

        do {
            let result = try await profileStore.refreshRemoteProfile(
                id,
                validator: try makeProfileValidator()
            )
            profiles = try await profileStore.profiles()
            if activeProfileID == id, case .updated = result {
                try await performActivateProfile(
                    id,
                    force: true,
                    rollbackSnapshot: rollbackSnapshot
                )
            }
            return switch result {
            case .updated: .updated
            case .notModified: .unchanged
            }
        } catch {
            if let rollbackSnapshot {
                do {
                    try await profileStore.restoreProfile(
                        metadata: rollbackSnapshot.metadata,
                        configurationData: rollbackSnapshot.configurationData
                    )
                    profiles = try await profileStore.profiles()
                } catch {
                    appendSupervisorLog(
                        "Subscription rollback failed: \(error.localizedDescription)"
                    )
                }
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

        guard let profileStore else { return }
        do {
            try await profileStore.removeProfile(id)
            profiles = try await profileStore.profiles()
            errorMessage = nil
        } catch {
            recordOperationFailure(error, context: "Profile removal")
        }
    }

    func toggleConnection() async {
        guard begin(.connection) else { return }
        defer { end(.connection) }

        if isConnected || isBusy {
            _ = await performDisconnect()
        } else {
            let connected = await performConnect()
            if connected, autoEnableSystemProxy {
                await enableSystemProxyAfterConnect()
            }
        }
    }

    func connect() async {
        guard begin(.connection) else { return }
        defer { end(.connection) }
        let connected = await performConnect()
        if connected, autoEnableSystemProxy {
            await enableSystemProxyAfterConnect()
        }
    }

    func disconnect() async {
        guard begin(.connection) else { return }
        defer { end(.connection) }
        _ = await performDisconnect()
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
        guard let activeConfigURL else {
            selection = .profiles
            errorMessage = "Add or select a profile before connecting."
            return false
        }

        do {
            errorMessage = nil
            let binaryURL = try binaryLocator.locate()
            let secret = try secretStore.loadOrCreate()
            let homeDirectory = try coreHomeDirectory()
            try geoDataInstaller.installIfNeeded(into: homeDirectory)
            let controllerPort = try localPortProbe.availableTCPPort()
            let configuration = CoreLaunchConfiguration(
                binaryURL: binaryURL,
                homeDirectory: homeDirectory,
                configURL: activeConfigURL,
                controllerPort: UInt16(controllerPort),
                secret: secret
            )
            try await supervisor.start(configuration)
            let state = await supervisor.state()
            coreState = state
            if case let .running(session) = state {
                await controllerDidStart(session)
            }
            if isConnected, controllerIsReady, networkCapturePreferences.enabled {
                await performNetworkCaptureActivation()
            }
            return isConnected && controllerIsReady
        } catch is CancellationError {
            return false
        } catch {
            errorMessage = error.localizedDescription
            appendSupervisorLog("Connection failed: \(error.localizedDescription)")
            return false
        }
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
                errorMessage = "The proxy core could not be confirmed stopped."
            }
            return false
        }
        stopControllerStreams()
        return true
    }

    func setMode(_ mode: String) async {
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
            errorMessage = "This proxy group is selected automatically for each connection."
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
            errorMessage = "This proxy group does not have an automatic override to clear."
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
        await loadProviders(using: apiClient, generation: controllerGeneration)
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
        guard enabled != networkCapturePreferences.enabled else { return }
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
        dnsEnabled: Bool? = nil
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
        let wasConnected = isConnected || isBusy
        do {
            if enabled {
                networkExtensionMihomoListener = try makeNetworkExtensionMihomoListener(
                    for: rules,
                    reusing: previous.enabled ? previousListener : nil
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
                return
            }

            // Matcher, priority, and action edits can be committed directly to
            // the running provider when the existing private Mihomo listeners
            // already cover every requested route. Existing relays retain the
            // plan they started with; new flows use the new revision.
            if previous.enabled,
               enabled,
               wasConnected,
               isConnected,
               controllerIsReady,
               candidate.dnsEnabled == previous.dnsEnabled,
               networkExtensionMihomoListener == previousListener,
               case let .on(activeRevision) = networkCaptureState,
               activeRevision == previous.snapshot.revision,
               let listener = networkExtensionMihomoListener {
                try await localPortProbe.waitUntilListening(
                    ports: Set(listener.routeListeners.map { Int($0.port) })
                )
                let configuration = try NetworkExtensionRuntimeConfiguration(
                    preferences: candidate,
                    mihomoListener: listener
                )
                let updateOutcome = try await networkExtensionControl
                    .updateRuntimeConfiguration(configuration)
                guard updateOutcome == .running else {
                    throw AppModelError.profileActivationFailed(
                        "The live App Routing update did not reach a verified running state."
                    )
                }
                networkCaptureState = .on(revision: configuration.revision)
                appRoutingProviderStatusFailureCount = 0
                appRoutingProviderLastVerifiedAt = Date()
                dnsProxyRuntimeFailureCount = 0
                dnsProxyAutomaticallyDisabled = false
                markStreamHealthy(.appRouting)
                startDNSProxyRuntimeMonitor()
                launchAppRoutingActivityMonitor()
                networkCaptureRollbackFailure = nil
                networkCaptureChangeReceipt = NetworkCaptureChangeReceipt(
                    completedAt: Date(),
                    duration: Date().timeIntervalSince(transactionStartedAt),
                    outcome: .rulesUpdatedLive(dnsEnabled: candidate.dnsEnabled)
                )
                appendSupervisorLog(
                    "App Routing rules were updated live; Mihomo and existing relays stayed connected."
                )
                return
            }

            if wasConnected {
                guard await performDisconnect() else {
                    throw AppModelError.networkCaptureDisableFailed
                }
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
                        errorMessage ?? "The core could not restart with network capture settings."
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
                    return
                case let .failed(message):
                    throw AppModelError.profileActivationFailed(
                        "App Routing activation failed verification: \(message)"
                    )
                case .on, .waitingForConnection, .enabling, .awaitingUserApproval,
                     .off, .disabling:
                    throw AppModelError.profileActivationFailed(
                        "App Routing did not reach a verified running state."
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
        } catch {
            let primaryError = error
            var rollbackFailures: [String] = []

            do {
                networkExtensionMihomoListener = previous.enabled ? previousListener : nil
                networkCapturePreferences = try await store.replaceRules(
                    previous.snapshot.rules,
                    enabled: previous.enabled,
                    dnsEnabled: previous.dnsEnabled,
                    failOpen: previous.failOpen
                )
            } catch {
                rollbackFailures.append(
                    "saved App Routing settings: \(error.localizedDescription)"
                )
            }

            if isConnected || isBusy {
                let disconnected = await performDisconnect()
                if !disconnected {
                    rollbackFailures.append(
                        "running core: could not stop it before restoration"
                    )
                }
            }

            do {
                let rollback = try await activateStoredProfile(
                    activeProfileID,
                    validator: try makeProfileValidator()
                )
                self.activeProfileID = rollback.profileID
                activeConfigURL = rollback.configurationURL
                profiles = try await profileStore.profiles()
            } catch {
                rollbackFailures.append(
                    "active profile: \(error.localizedDescription)"
                )
            }

            if wasConnected {
                let reconnected = await performConnect()
                if !reconnected {
                    rollbackFailures.append(
                        "mihomo core: \(errorMessage ?? "the previous session could not be restarted")"
                    )
                }
            }

            if systemProxyWasOn {
                if networkCapturePreferences.enabled {
                    rollbackFailures.append(
                        "System Proxy: App Routing remained enabled, so restoring the mutually exclusive proxy would be unsafe"
                    )
                } else {
                    await performEnableSystemProxy()
                    if case .on = systemProxyState {
                        appendSupervisorLog(
                            "Network capture rollback restored the previously enabled macOS System Proxy."
                        )
                    } else {
                        rollbackFailures.append(
                            "System Proxy: \(errorMessage ?? "the previous macOS proxy could not be re-enabled and verified")"
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
        guard networkCapturePreferences.enabled else {
            networkCaptureState = .off
            return
        }
        guard let listener = activeNetworkExtensionMihomoListener else {
            reportNetworkCaptureFailure("The private mihomo listener is unavailable.")
            return
        }
        networkCaptureState = .enabling
        dnsProxyRuntimeStatus = nil
        dnsProxyRuntimeError = nil
        dnsProxyAutomaticallyDisabled = false
        do {
            try await localPortProbe.waitUntilListening(ports: [Int(listener.port)])
            let configuration = try NetworkExtensionRuntimeConfiguration(
                preferences: networkCapturePreferences,
                mihomoListener: listener
            )
            switch try await networkExtensionControl.enable(
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
            ) {
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
        errorMessage = "App Routing couldn’t start: \(message)"
        appendSupervisorLog("Network Extension activation failed: \(message)")
    }

    @discardableResult
    private func performNetworkCaptureDeactivation() async -> Bool {
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
            return true
        } catch {
            let message = error.localizedDescription
            networkCaptureState = .failed(message)
            errorMessage = message
            appendSupervisorLog("Network Extension shutdown failed: \(message)")
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
        if case .on = systemProxyState { return }
        if case .enabling = systemProxyState { return }
        guard !networkCapturePreferences.enabled else {
            errorMessage = "Turn off per-application network capture before enabling the macOS system proxy."
            return
        }
        guard isConnected, runtimeConfig != nil else {
            errorMessage = "Connect the core before enabling the macOS system proxy."
            return
        }
        guard let profileLayout else {
            errorMessage = "The application state directory is unavailable."
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
            guard generation == controllerGeneration, isConnected else {
                _ = await performDisableSystemProxy()
                return
            }
            systemProxyGuardLastVerifiedAt = Date()
            systemProxyState = .on
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
            try await systemProxyManager.apply(
                endpoints: endpoints,
                bypassDomains: updatedPreferences.effectiveBypassDomains
            )
            guard try await systemProxyManager.configurationMatches(
                endpoints: endpoints,
                bypassDomains: updatedPreferences.effectiveBypassDomains
            ) else {
                throw AppModelError.systemProxyGuardVerificationFailed
            }
            try await systemProxyPreferencesStore.save(updatedPreferences)
            systemProxyPreferences = updatedPreferences
            systemProxyGuardFailure = nil
            systemProxyGuardLastVerifiedAt = Date()
            systemProxyState = .on
            systemProxySettingsReceipt = SystemProxySettingsReceipt(
                completedAt: Date(),
                outcome: .appliedAndVerified
            )
            startSystemProxyGuard(endpoints: endpoints)
        } catch {
            let updateError = error
            var rollbackError: (any Error)?
            do {
                try await systemProxyManager.apply(
                    endpoints: endpoints,
                    bypassDomains: previousPreferences.effectiveBypassDomains
                )
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
                "The macOS System Proxy is not enabled."
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
            }
            return
        }
        let interval = systemProxyPreferences.guardIntervalSeconds
        let bypassDomains = systemProxyPreferences.effectiveBypassDomains
        systemProxyGuardTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(interval))
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
        bypassDomains: [String]
    ) async {
        guard systemProxyGuardCanVerify else { return }
        do {
            let matches = try await systemProxyManager.configurationMatches(
                endpoints: endpoints,
                bypassDomains: bypassDomains
            )
            guard systemProxyGuardCanVerify else { return }
            if !matches {
                let detectedAt = Date()
                try await systemProxyManager.apply(
                    endpoints: endpoints,
                    bypassDomains: bypassDomains
                )
                guard systemProxyGuardCanVerify else { return }
                let repairedConfigurationMatches = try await systemProxyManager.configurationMatches(
                    endpoints: endpoints,
                    bypassDomains: bypassDomains
                )
                guard systemProxyGuardCanVerify else { return }
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
            }
        } catch {
            guard systemProxyGuardCanVerify else { return }
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
            let message = "MClash could not verify or restore the macOS system proxy after \(count) consecutive attempts. Last error: \(reason)"
            systemProxyState = .failed(message)
            if count == Self.systemProxyGuardFailureThreshold {
                appendSupervisorLog(message)
            }
        }
    }

    @discardableResult
    private func performSystemProxyRestore() async -> Bool {
        guard let profileLayout else {
            let message = "The application state directory is unavailable."
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
        shutdownInProgress = true
        subscriptionUpdateTask?.cancel()
        subscriptionUpdateTask = nil
        systemProxyGuardTask?.cancel()
        systemProxyGuardTask = nil
        await cancelStartupPreparation()
        shouldReenableSystemProxyAfterCrash = false
        if let operation = systemProxyEnableOperation {
            await operation.task.value
        }
        if networkCaptureIsActive,
           !(await performNetworkCaptureDeactivation()) {
            shutdownInProgress = false
            return false
        }
        if systemProxyEnabled || hasSystemProxySnapshot {
            guard await performDisableSystemProxy() else {
                // Keep the failure user-recoverable without allowing another Scene
                // task to begin an automatic restore/authorization loop.
                if hasSystemProxySnapshot { prepared = true }
                shutdownInProgress = false
                return false
            }
        }
        guard await stopCore() else {
            shutdownInProgress = false
            return false
        }
        return true
    }

    func forceShutdown() async {
        shutdownInProgress = true
        subscriptionUpdateTask?.cancel()
        subscriptionUpdateTask = nil
        systemProxyGuardTask?.cancel()
        systemProxyGuardTask = nil
        await cancelStartupPreparation()
        shouldReenableSystemProxyAfterCrash = false
        if let operation = systemProxyEnableOperation {
            await operation.task.value
        }
        if networkCaptureIsActive {
            _ = await performNetworkCaptureDeactivation()
        }
        _ = await stopCore()
        stopControllerStreams()
    }

    private func cancelStartupPreparation() async {
        guard let operation = preparationOperation else { return }
        operation.task.cancel()
        await operation.task.value
        if preparationOperation?.id == operation.id {
            preparationOperation = nil
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
            if networkCaptureIsActive {
                try await networkExtensionControl.clearAppRoutingActivity()
            }
            appRoutingActivities.removeAll(keepingCapacity: true)
            appRoutingActivitiesByIdentifier.removeAll(keepingCapacity: true)
            appRoutingRuleStatistics.removeAll(keepingCapacity: true)
            appRoutingActivityCursor = 0
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
        trafficHistoryPersistenceChoice = enabled ? .persistent : .sessionOnly
        trafficHistoryPersistGeneration &+= 1
        trafficHistoryPersistTask?.cancel()
        trafficHistoryPersistTask = nil
        queuedTrafficHistoryCompletions.removeAll(keepingCapacity: false)
        queuedTrafficHistoryIdentifiers.removeAll(keepingCapacity: false)

        guard enabled else {
            persistentTrafficHistoryStore = nil
            trafficHistoryTodaySnapshot = nil
            trafficHistoryWeekSnapshot = nil
            trafficHistoryRuntimeState = .sessionOnly
            return
        }
        await openPersistentTrafficHistory()
    }

    func setTrafficHistoryRetention(_ retention: TrafficHistoryRetention) async {
        guard let store = persistentTrafficHistoryStore else { return }
        do {
            try await store.setRetention(retention)
            trafficHistoryRetention = retention
            await refreshPersistentTrafficHistorySnapshots()
        } catch {
            markPersistentTrafficHistoryUnavailable(
                "MClash could not update the traffic history retention period: \(error.localizedDescription)"
            )
        }
    }

    @discardableResult
    func clearTrafficHistory() async -> Bool {
        clearClosedConnectionHistory()
        guard await clearAppRoutingActivity() else { return false }

        guard let store = persistentTrafficHistoryStore else { return true }
        do {
            _ = try await store.clear()
            persistedTrafficHistoryIdentifiers.removeAll(keepingCapacity: true)
            persistedTrafficHistoryIdentifierOrder.removeAll(keepingCapacity: true)
            queuedTrafficHistoryCompletions.removeAll(keepingCapacity: true)
            queuedTrafficHistoryIdentifiers.removeAll(keepingCapacity: true)
            await refreshPersistentTrafficHistorySnapshots()
            return true
        } catch {
            markPersistentTrafficHistoryUnavailable(
                "MClash could not clear the persistent traffic history: \(error.localizedDescription)"
            )
            return false
        }
    }

    func refreshPersistentTrafficHistorySnapshots() async {
        guard let store = persistentTrafficHistoryStore else { return }
        do {
            let today = try await store.snapshot(for: .today)
            let week = try await store.snapshot(for: .week)
            trafficHistoryTodaySnapshot = today
            trafficHistoryWeekSnapshot = week
            trafficHistoryRuntimeState = .ready(lastUpdatedAt: Date())
        } catch {
            markPersistentTrafficHistoryUnavailable(
                "MClash could not read the persistent traffic history: \(error.localizedDescription)"
            )
        }
    }

    private func prepareTrafficHistoryPersistenceIfNeeded() async {
        switch trafficHistoryPersistenceChoice {
        case .undecided:
            trafficHistoryRuntimeState = .notConfigured
        case .sessionOnly:
            trafficHistoryRuntimeState = .sessionOnly
        case .persistent:
            await openPersistentTrafficHistory()
        }
    }

    private func openPersistentTrafficHistory() async {
        guard let profileLayout else {
            markPersistentTrafficHistoryUnavailable(
                "The MClash Application Support directory is unavailable."
            )
            return
        }
        trafficHistoryRuntimeState = .loading
        let result = await Task.detached(priority: .utility) {
            TrafficHistoryStore.open(layout: profileLayout)
        }.value
        switch result {
        case let .ready(store):
            persistentTrafficHistoryStore = store
            do {
                trafficHistoryRetention = try await store.retention()
                await refreshPersistentTrafficHistorySnapshots()
                schedulePersistentTrafficHistory(from: flowLedger)
            } catch {
                markPersistentTrafficHistoryUnavailable(
                    "MClash opened traffic history but could not verify it: \(error.localizedDescription)"
                )
            }
        case let .unavailable(reason):
            markPersistentTrafficHistoryUnavailable(
                Self.trafficHistoryUnavailableDescription(reason)
            )
        }
    }

    private func markPersistentTrafficHistoryUnavailable(_ reason: String) {
        persistentTrafficHistoryStore = nil
        trafficHistoryRuntimeState = .unavailable(reason)
        appendSupervisorLog("Persistent traffic history is unavailable: \(reason)")
    }

    private static func trafficHistoryUnavailableDescription(
        _ reason: TrafficHistoryStoreUnavailableReason
    ) -> String {
        switch reason {
        case .cannotCreatePrivateDirectory:
            "MClash could not create its private TrafficHistory directory."
        case .cannotOpenDatabase:
            "MClash could not open its local traffic history database."
        case .corruptedDatabase:
            "The local traffic history database failed its integrity check. It was left untouched for recovery."
        case let .newerSchema(found, supported):
            "Traffic history uses schema \(found), but this version of MClash supports schema \(supported). The database was left untouched."
        case .migrationFailed:
            "MClash could not migrate the local traffic history database. It was left untouched."
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
                            title: "MClash Needs Attention",
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
                if systemProxyEnabled || hasSystemProxySnapshot {
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

    private func handleRunningSession(_ session: CoreSession) async {
        await controllerDidStart(session)
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
        shouldReenableSystemProxyAfterCrash = false
        guard isConnected, controllerIsReady else { return }
        await performEnableSystemProxy()
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
            guard generation == controllerGeneration,
                  activeControllerEndpoint == session.endpoint,
                  isConnected else { return }
            apiClient = client
            runtimeConfig = config
            proxyProfileStructure = loadProxyProfileStructure()
            applyProxyCollection(proxies, profileStructure: proxyProfileStructure)
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

    private func ensureLocalProxyListeners(
        _ initialConfig: MihomoConfig,
        using client: MihomoAPIClient
    ) async throws -> MihomoConfig {
        managedMixedPort = nil
        let requiresExactListeners = runtimeOverrides.ports.hasExplicitLocalProxyListener
        if let ports = resolvedProxyPorts(in: initialConfig) {
            let requiredPorts = try requiredProxyProtocolPorts(
                effectiveHTTPPort: ports.http,
                effectiveSOCKSPort: ports.socks,
                config: initialConfig
            )
            do {
                try await localPortProbe.waitUntilProxyProtocols(
                    httpPorts: requiredPorts.http,
                    socksPorts: requiredPorts.socks
                )
                return initialConfig
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                if requiresExactListeners {
                    throw AppModelError.explicitLocalProxyListenersUnavailable(
                        Set([ports.http, ports.socks]).sorted()
                    )
                }
                appendSupervisorLog(
                    "Configured proxy listeners were unavailable; applying a temporary MClash mixed port."
                )
            }
        } else {
            if requiresExactListeners {
                throw AppModelError.explicitLocalProxyListenersIncomplete
            }
            appendSupervisorLog(
                "The profile has no complete local HTTP/SOCKS listener; applying a temporary MClash mixed port."
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

    private func resolvedProxyPorts(in config: MihomoConfig) -> (http: Int, socks: Int)? {
        guard let http = positivePort(config.port) ?? positivePort(config.mixedPort),
              let socks = positivePort(config.socksPort) ?? positivePort(config.mixedPort) else {
            return nil
        }
        return (http, socks)
    }

    private func requiredProxyProtocolPorts(
        effectiveHTTPPort: Int,
        effectiveSOCKSPort: Int,
        config: MihomoConfig
    ) throws -> (http: Set<Int>, socks: Set<Int>) {
        var httpPorts: Set<Int> = [effectiveHTTPPort]
        var socksPorts: Set<Int> = [effectiveSOCKSPort]
        let overrides = runtimeOverrides.ports

        if let requested = overrides.port {
            guard config.port == requested else {
                throw AppModelError.explicitLocalProxyListenerRejected(
                    field: "HTTP",
                    requested: requested,
                    actual: config.port
                )
            }
            if let port = positivePort(config.port) { httpPorts.insert(port) }
        }
        if let requested = overrides.socksPort {
            guard config.socksPort == requested else {
                throw AppModelError.explicitLocalProxyListenerRejected(
                    field: "SOCKS5",
                    requested: requested,
                    actual: config.socksPort
                )
            }
            if let port = positivePort(config.socksPort) { socksPorts.insert(port) }
        }
        if let requested = overrides.mixedPort {
            guard config.mixedPort == requested else {
                throw AppModelError.explicitLocalProxyListenerRejected(
                    field: "Mixed",
                    requested: requested,
                    actual: config.mixedPort
                )
            }
            if let port = positivePort(config.mixedPort) {
                httpPorts.insert(port)
                socksPorts.insert(port)
            }
        }
        return (httpPorts, socksPorts)
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
            let message = "Routing changed, but existing connections could not be closed: \(error.localizedDescription)"
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
            guard generation == controllerGeneration, isConnected else { return }
            proxyProviders = proxyCollection.providers.values.sorted {
                $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
            loadedAtLeastOneCollection = true
        } catch {
            guard generation == controllerGeneration, isConnected else { return }
            failures.append("Proxy providers: \(error.localizedDescription)")
        }

        do {
            let ruleCollection = try await client.fetchRuleProviders()
            guard generation == controllerGeneration, isConnected else { return }
            ruleProviders = ruleCollection.providers.values.sorted {
                $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
            loadedAtLeastOneCollection = true
        } catch {
            guard generation == controllerGeneration, isConnected else { return }
            failures.append("Rule providers: \(error.localizedDescription)")
        }

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
            // The connection feed is also the low-cost accounting source for
            // completed session and persistent history. Keep it alive while
            // the core runs, but skip presentation-only transforms below when
            // no surface needs them.
            shouldRun: true,
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
            let reason = "No \(stream.freshnessDescription) sample was received for more than \(Int(deadline)) seconds."
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

    private func startAppRoutingActivityMonitor() {
        appRoutingActivityTask?.cancel()
        appRoutingActivityCursor = 0
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
        launchAppRoutingActivityMonitor()
    }

    private func launchAppRoutingActivityMonitor() {
        appRoutingActivityTask?.cancel()
        appRoutingMonitorGeneration &+= 1
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
                var hasMore = true
                var activityUpdates: [AppRoutingActivity] = []
                while hasMore,
                      appRoutingMonitorShouldContinue(
                        generation: generation,
                        expectedRevision: expectedRevision
                      ) {
                    let batch = try await networkExtensionControl.appRoutingActivity(
                        after: appRoutingActivityCursor,
                        limit: 250
                    )
                    guard appRoutingMonitorShouldContinue(
                        generation: generation,
                        expectedRevision: expectedRevision
                    ) else { return }
                    if let dropped = batch.droppedBeforeSequence,
                       appRoutingActivityCursor > 0,
                       appRoutingActivityCursor < dropped {
                        appRoutingActivityDroppedCount = Self.saturatingAdd(
                            appRoutingActivityDroppedCount,
                            dropped - appRoutingActivityCursor
                        )
                        appRoutingActivities.removeAll(keepingCapacity: true)
                        appRoutingActivitiesByIdentifier.removeAll(keepingCapacity: true)
                        appRoutingRuleStatistics.removeAll(keepingCapacity: true)
                        appRoutingActivityCursor = 0
                        appRoutingTrafficRateTracker.reset()
                        appRoutingTrafficRates = .zero
                        appRoutingActiveCount = 0
                        appRoutingActivityCoverageStartedAt = Date()
                        activityUpdates.removeAll(keepingCapacity: true)
                        continue
                    }
                    activityUpdates.append(contentsOf: batch.activities)
                    appRoutingActivityCursor = batch.nextCursor
                    hasMore = batch.hasMore
                    if hasMore {
                        await Task.yield()
                    }
                }
                let processingCursor = appRoutingActivityCursor
                let processingRevision = appRoutingActivityStateRevision
                let currentActivities = appRoutingActivities
                let currentActivitiesByIdentifier = appRoutingActivitiesByIdentifier
                let currentRuleStatistics = appRoutingRuleStatistics
                let currentRateTracker = appRoutingTrafficRateTracker
                let sampledAt = Date()
                let worker = Task.detached(priority: .utility) {
                    Self.processAppRoutingActivities(
                        updates: activityUpdates,
                        currentActivities: currentActivities,
                        currentActivitiesByIdentifier: currentActivitiesByIdentifier,
                        currentRuleStatistics: currentRuleStatistics,
                        currentRateTracker: currentRateTracker,
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
                ), appRoutingActivityCursor == processingCursor,
                   appRoutingActivityStateRevision == processingRevision else { continue }

                appRoutingTrafficRateTracker = processed.rateTracker
                appRoutingTrafficRates = processed.trafficRates
                appRoutingActiveCount = processed.activeCount
                if processed.mergedUpdates {
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
                        neededForAccounting: processed.needsAccounting
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
                    let message = "MClash lost contact with the App Routing provider after \(failureAttempt) consecutive activity checks. Traffic capture can no longer be verified. Last error: \(error.localizedDescription)"
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
              generation == appRoutingMonitorGeneration else { return false }
        guard let expectedRevision else { return true }
        return networkCaptureState.isActive(revision: expectedRevision)
    }

    private func startDNSProxyRuntimeMonitor() {
        dnsProxyRuntimeTask?.cancel()
        dnsProxyMonitorGeneration &+= 1
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
                await refreshDNSProxyRuntime(
                    expectedRevision: expectedRevision,
                    monitorGeneration: generation
                )
                do {
                    try await Task.sleep(
                        for: presentationTelemetryPolicy.appRoutingActivity
                            ? .seconds(2)
                            : .seconds(5)
                    )
                } catch {
                    return
                }
            }
        }
    }

    private func refreshDNSProxyRuntime(
        expectedRevision: UInt64,
        monitorGeneration: UInt64
    ) async {
        guard networkCapturePreferences.dnsEnabled,
              !dnsProxyAutomaticallyDisabled,
              dnsProxyMonitorShouldContinue(
                generation: monitorGeneration,
                expectedRevision: expectedRevision
              ) else { return }
        do {
            guard let status = try await networkExtensionControl
                .dnsProviderRuntimeStatus() else {
                throw NSError(
                    domain: "one.leaper.mclash.dns-runtime",
                    code: 0,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "DNS Provider runtime status is unavailable"
                    ]
                )
            }
            guard dnsProxyMonitorShouldContinue(
                generation: monitorGeneration,
                expectedRevision: expectedRevision
            ) else { return }
            guard status.isOperational else {
                throw NSError(
                    domain: "one.leaper.mclash.dns-runtime",
                    code: 1,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "DNS Provider revision \(status.revision) is \(status.phase.rawValue) and backendReady=\(status.backendReady)"
                    ]
                )
            }
            dnsProxyRuntimeStatus = status
            dnsProxyRuntimeError = nil
            dnsProxyRuntimeFailureCount = 0
            dnsProxyLastVerifiedAt = Date()
        } catch {
            guard dnsProxyMonitorShouldContinue(
                generation: monitorGeneration,
                expectedRevision: expectedRevision
            ) else { return }
            let runtimeFailure = error
            dnsProxyRuntimeStatus = nil
            dnsProxyRuntimeFailureCount += 1
            dnsProxyRuntimeError = runtimeFailure.localizedDescription
            guard dnsProxyRuntimeFailureCount >= 2 else { return }
            do {
                // DNS is part of the default App Routing data plane. If its
                // persisted manager or Provider heartbeat cannot be verified,
                // stop both providers so the UI never claims a partially
                // active routing mode.
                guard dnsProxyMonitorShouldContinue(
                    generation: monitorGeneration,
                    expectedRevision: expectedRevision
                ) else { return }
                try await networkExtensionControl.disable()
                guard dnsProxyMonitorShouldContinue(generation: monitorGeneration) else {
                    return
                }
                dnsProxyAutomaticallyDisabled = true
                let message = "App Routing and DNS Routing were stopped together because the DNS Provider heartbeat or Mihomo backend could not be verified. macOS system DNS was restored. Last error: \(runtimeFailure.localizedDescription)"
                dnsProxyRuntimeError = message
                networkCaptureState = .failed(message)
                appendSupervisorLog(message)
            } catch let shutdownFailure {
                guard dnsProxyMonitorShouldContinue(
                    generation: monitorGeneration,
                    expectedRevision: expectedRevision
                ) else { return }
                let message = "DNS Routing became unverified and MClash could not confirm that the coupled App Routing data plane shut down safely. Runtime error: \(runtimeFailure.localizedDescription) Shutdown error: \(shutdownFailure.localizedDescription)"
                dnsProxyRuntimeError = message
                networkCaptureState = .failed(message)
                appendSupervisorLog(message)
            }
        }
    }

    private func dnsProxyMonitorShouldContinue(
        generation: UInt64,
        expectedRevision: UInt64? = nil
    ) -> Bool {
        guard !Task.isCancelled,
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
        monitorGeneration: UInt64? = nil
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
        do {
            let status = try await networkExtensionControl.providerRuntimeStatus()
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

            appRoutingProviderStatusFailureCount = 0
            appRoutingProviderLastVerifiedAt = Date()
            appRoutingActivityError = nil
            degradedStreams.remove(.appRouting)
            return true
        } catch {
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
            appRoutingProviderStatusFailureCount += 1
            let count = appRoutingProviderStatusFailureCount
            let reason = error.localizedDescription
            appRoutingActivityError = "Provider verification failed: \(reason)"
            markStreamDegraded(.appRouting, error: error, attempt: count)

            if count >= Self.appRoutingProviderFailureThreshold {
                let message = "App Routing is no longer verified after \(count) consecutive provider checks. Expected active revision \(expectedRevision). Last error: \(reason)"
                networkCaptureState = .failed(message)
                appendSupervisorLog(message)
            } else if count == 1 {
                appendSupervisorLog(
                    "App Routing provider verification is retrying: \(reason)"
                )
            }
            return false
        }
    }

    private func stopAppRoutingActivityMonitor() {
        appRoutingActivityTask?.cancel()
        appRoutingActivityTask = nil
        appRoutingMonitorGeneration &+= 1
        dnsProxyRuntimeTask?.cancel()
        dnsProxyRuntimeTask = nil
        dnsProxyMonitorGeneration &+= 1
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
        guard needsRefresh, flowLedgerTask == nil else { return }
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
            let worker = Task.detached(priority: .utility) {
                FlowLedger(
                    activeConnections: activeConnections,
                    recentlyClosedConnections: closedConnections,
                    appRoutingActivities: activities
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
        guard persistentTrafficHistoryStore != nil,
              trafficHistoryPersistenceChoice == .persistent else { return }

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
              persistentTrafficHistoryStore != nil,
              !queuedTrafficHistoryCompletions.isEmpty else { return }

        trafficHistoryPersistGeneration &+= 1
        let generation = trafficHistoryPersistGeneration
        trafficHistoryPersistTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while !Task.isCancelled,
                  generation == self.trafficHistoryPersistGeneration,
                  let store = self.persistentTrafficHistoryStore,
                  !self.queuedTrafficHistoryCompletions.isEmpty {
                let count = min(250, self.queuedTrafficHistoryCompletions.count)
                let batch = Array(self.queuedTrafficHistoryCompletions.prefix(count))
                self.queuedTrafficHistoryCompletions.removeFirst(count)
                do {
                    _ = try await store.ingest(batch)
                    guard !Task.isCancelled,
                          generation == self.trafficHistoryPersistGeneration else {
                        return
                    }
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
                          generation == self.trafficHistoryPersistGeneration else {
                        return
                    }
                    for completion in batch {
                        self.queuedTrafficHistoryIdentifiers.remove(
                            completion.checkpointIdentifier
                        )
                    }
                    self.trafficHistoryPersistTask = nil
                    self.markPersistentTrafficHistoryUnavailable(
                        "MClash could not write the persistent traffic history: \(error.localizedDescription)"
                    )
                    return
                }
            }
            guard generation == self.trafficHistoryPersistGeneration else { return }
            self.trafficHistoryPersistTask = nil
            if !Task.isCancelled {
                await self.refreshPersistentTrafficHistorySnapshots()
            }
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
            with: "the subscription endpoint",
            options: .caseInsensitive
        )
        if let host = url.host, !host.isEmpty {
            redacted = redacted.replacingOccurrences(
                of: host,
                with: "the subscription host",
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
        guard canPerform(operation) else { return false }
        return operations.insert(operation).inserted
    }

    private func end(_ operation: Operation) {
        operations.remove(operation)
    }

    private func systemProxySnapshotURL(layout: ProfileDirectoryLayout) -> URL {
        layout.stateDirectory.appending(path: "system-proxy-snapshot.json")
    }

    private func positivePort(_ port: Int) -> Int? {
        port > 0 ? port : nil
    }

    private var activeNetworkExtensionMihomoListener: NetworkExtensionMihomoListenerConfiguration? {
        networkCapturePreferences.enabled ? networkExtensionMihomoListener : nil
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
        case .off, .waitingForConnection, .enabling, .awaitingUserApproval:
            true
        case .disabling, .requiresReboot, .failed:
            false
        }
    }

    private func makeNetworkExtensionMihomoListener(
        for rules: [CaptureRule],
        reusing existing: NetworkExtensionMihomoListenerConfiguration? = nil
    ) throws
        -> NetworkExtensionMihomoListenerConfiguration
    {
        let requestedRoutes = Set<MihomoRoute>(rules.lazy.filter(\.enabled).compactMap { rule in
            guard case let .mihomo(route) = rule.action,
                  route != .profileRules else { return nil }
            return route
        })
        guard requestedRoutes.count <= Self.maximumDedicatedMihomoRoutes else {
            throw AppModelError.tooManyNetworkCaptureRoutes(
                actual: requestedRoutes.count,
                maximum: Self.maximumDedicatedMihomoRoutes
            )
        }
        if let existing {
            let availableRoutes = Set(existing.routeListeners.map(\.route))
            if requestedRoutes.isSubset(of: availableRoutes) {
                return existing
            }
        }

        var randomBytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, randomBytes.count, &randomBytes)
        guard status == errSecSuccess else {
            throw AppModelError.secureRandomGenerationFailed(status)
        }
        let password = Data(randomBytes).base64EncodedString()
        let authentication = try NetworkExtensionMihomoAuthentication(
            username: "mclash-network-extension",
            password: password
        )
        let sortedRoutes = requestedRoutes.sorted {
            Self.mihomoRouteSortKey($0) < Self.mihomoRouteSortKey($1)
        }
        let ports = try localPortProbe.availableTCPAndUDPPorts(
            count: sortedRoutes.count + 1
        )
        var routePorts: [MihomoRoute: Int] = [:]
        for (route, port) in zip(sortedRoutes, ports.dropFirst()) {
            routePorts[route] = port
        }
        return try NetworkExtensionMihomoListenerConfiguration(
            port: ports[0],
            authentication: authentication,
            routePorts: routePorts
        )
    }

    private static func mihomoRouteSortKey(_ route: MihomoRoute) -> String {
        switch route {
        case .profileRules: "0:profile"
        case .global: "1:global"
        case let .group(group): "2:group:\(group)"
        }
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
        runtimeOverrides.ports.mixedPort == nil ? .profile : .override
    }

    private func listenerEndpoint(
        kind: LocalListenerKind,
        port: Int?,
        isOverridden: Bool
    ) -> LocalListenerEndpoint? {
        port.map {
            LocalListenerEndpoint(
                kind: kind,
                host: "127.0.0.1",
                port: $0,
                source: isOverridden ? .override : .profile
            )
        }
    }

    private var hasSystemProxySnapshot: Bool {
        guard let profileLayout else { return false }
        return FileManager.default.fileExists(
            atPath: systemProxySnapshotURL(layout: profileLayout).path
        )
    }

    static let autoConnectOnLaunchKey = "network.autoConnectOnLaunch"
    static let autoEnableSystemProxyKey = "network.autoEnableSystemProxy"
    static let closeConnectionsOnRoutingChangeKey = "network.closeConnectionsOnRoutingChange"
    static let trafficHistoryPersistenceChoiceKey = "traffic.history.persistenceChoice"
    static let notificationsEnabledKey = "application.notificationsEnabled"
    static let systemProxyGuardFailureThreshold = 3
    static let appRoutingProviderFailureThreshold = 3
    static let appRoutingProviderStatusCheckInterval = 5
    static let maximumDedicatedMihomoRoutes = 64

    nonisolated private static func saturatingAdd(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
        let (value, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? .max : value
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
             .changeNetworkCapture:
            true
        case .changeMode,
             .selectProxy,
             .clearProxyOverride,
             .measureDelay,
             .measureGroupDelay,
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
             .changeNetworkCapture:
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

    var errorDescription: String? {
        switch self {
        case .profileStoreUnavailable:
            "The MClash profile store is unavailable."
        case .operationInProgress:
            "This operation is already in progress."
        case let .streamEnded(name):
            "\(name) stream ended unexpectedly."
        case .systemProxyRestoreFailed:
            "MClash could not restore the previous macOS proxy settings, so the running core was left active."
        case .networkCaptureDisableFailed:
            "MClash could not stop Network Extension capture, so the mihomo core was left active."
        case let .secureRandomGenerationFailed(status):
            "MClash could not generate private Network Extension credentials (OSStatus \(status))."
        case let .profileActivationFailed(message):
            message
        case .localProxyPortsUnavailable:
            "The active profile does not expose both an HTTP and a SOCKS5 local proxy port. Add port/socks-port or mixed-port to the profile."
        case let .localProxyOverrideRejected(port):
            "mihomo did not accept MClash's temporary local proxy port \(port)."
        case .explicitLocalProxyListenersIncomplete:
            "The HTTP, SOCKS5, and Mixed overrides do not provide both HTTP and SOCKS5 service. Configure a Mixed port or complete HTTP and SOCKS5 ports."
        case let .explicitLocalProxyListenersUnavailable(ports):
            "The requested local proxy listener did not start on \(ports.map(String.init).joined(separator: ", ")). Choose available ports and try again."
        case let .explicitLocalProxyListenerRejected(field, requested, actual):
            "mihomo did not apply the requested \(field) listener port \(requested); it reported \(actual)."
        case .systemProxyGuardVerificationFailed:
            "The macOS system proxy still did not match MClash after reapplying it."
        case let .tooManyNetworkCaptureRoutes(actual, maximum):
            "App Routing requests \(actual) distinct Mihomo route targets; the safe maximum is \(maximum)."
        }
    }
}

private struct SystemProxyPreferenceRollbackFailure: LocalizedError {
    let updateReason: String
    let rollbackReason: String

    var errorDescription: String? {
        "The new macOS system proxy settings could not be verified, and MClash could not restore the previous settings. Update error: \(updateReason) Rollback error: \(rollbackReason)"
    }
}

private struct NetworkCaptureTransactionFailure: LocalizedError {
    let updateReason: String
    let rollbackReason: String

    var errorDescription: String? {
        "The App Routing change failed and MClash could not completely restore the previous network state. Update error: \(updateReason) Recovery error: \(rollbackReason)"
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
            let providerDetail = providerMessage.flatMap { $0.isEmpty ? nil : $0 }
                .map { " Provider message: \($0)" } ?? ""
            return "Provider reported running=\(running), captureEnabled=\(captureEnabled), revision=\(actualRevision); expected running=true, captureEnabled=true, revision=\(expectedRevision).\(providerDetail)"
        }
    }
}
