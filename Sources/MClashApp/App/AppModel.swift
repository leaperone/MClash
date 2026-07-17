import AppKit
import Foundation
import MClashNetworkShared
import Observation
import Security

@MainActor
@Observable
final class AppModel {
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

    enum LiveStream: Hashable {
        case traffic
        case connections
        case logs
        case proxies
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
        case enabling
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
        case profiles
        case rules
        case providers
        case connections
        case logs
        case settings

        var id: Self { self }

        var title: String {
            switch self {
            case .overview: "Overview"
            case .proxies: "Proxies"
            case .profiles: "Profiles"
            case .rules: "Rules"
            case .providers: "Providers"
            case .connections: "Connections"
            case .logs: "Logs"
            case .settings: "Settings"
            }
        }

        var symbol: String {
            switch self {
            case .overview: "gauge.with.dots.needle.50percent"
            case .proxies: "point.3.connected.trianglepath.dotted"
            case .profiles: "doc.text"
            case .rules: "list.bullet.rectangle"
            case .providers: "shippingbox"
            case .connections: "arrow.left.arrow.right"
            case .logs: "text.alignleft"
            case .settings: "gearshape"
            }
        }
    }

    var selection: Destination? = .overview
    var coreState: CoreRunState = .stopped
    var activeConfigURL: URL?
    var logs: [CoreLogLine] = []
    var errorMessage: String?
    var profiles: [ProfileMetadata] = []
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
    var proxyProviders: [MihomoProxyProvider] = []
    var ruleProviders: [MihomoRuleProvider] = []
    var rulesErrorMessage: String?
    var providersErrorMessage: String?
    var traffic = MihomoTraffic(upload: 0, download: 0, uploadTotal: 0, downloadTotal: 0)
    var trafficHistory: [TrafficSample] = []
    var connections: MihomoConnectionSnapshot? {
        didSet {
            recordClosedConnections(previous: oldValue, current: connections)
            proxyInspectorTrafficRevision &+= 1
            connectionsUseGlobalProxy = connections?.connections.contains {
                $0.chains.contains("GLOBAL")
            } == true
            updateGlobalProxyGroupRelevance()
        }
    }
    private(set) var recentlyClosedConnections: [ClosedConnectionRecord] = []
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
    private(set) var degradedStreams: Set<LiveStream> = []
    private(set) var operations: Set<Operation> = []

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
    private var apiLogTask: Task<Void, Never>?
    private var proxyRefreshTask: Task<Void, Never>?
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
    private var prepared = false
    private var preparationOperation: (id: UUID, task: Task<Void, Never>)?
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

        if let layout = profileDirectoryLayout ?? (try? ProfileDirectoryLayout.applicationSupport()) {
            profileLayout = layout
            profileStore = profileStoreOverride ?? (try? ProfileStore(layout: layout))
            if let overrideStore = try? RuntimeOverrideStore(profileLayout: layout) {
                runtimeOverrideCoordinator = RuntimeOverrideActivationCoordinator(
                    overrideStore: overrideStore
                )
            } else {
                runtimeOverrideCoordinator = nil
            }
            systemProxyPreferencesStore = try? SystemProxyPreferencesStore(
                profileLayout: layout
            )
            networkCaptureConfigurationStore = try? NetworkCaptureConfigurationStore(
                profileLayout: layout
            )
        } else {
            profileLayout = nil
            profileStore = nil
            runtimeOverrideCoordinator = nil
            systemProxyPreferencesStore = nil
            networkCaptureConfigurationStore = nil
        }

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
            try Task.checkCancellation()
            guard !shutdownInProgress else { return }
            if let profileStore, let profileLayout {
                if let runtimeOverrideCoordinator {
                    runtimeOverrides = try await runtimeOverrideCoordinator.overrides()
                }
                if let systemProxyPreferencesStore {
                    systemProxyPreferences = try await systemProxyPreferencesStore.load()
                }
                if let networkCaptureConfigurationStore {
                    networkCapturePreferences = try await networkCaptureConfigurationStore.load()
                    if networkCapturePreferences.enabled {
                        networkExtensionMihomoListener = try makeNetworkExtensionMihomoListener()
                    }
                }
                profiles = try await profileStore.profiles()
                activeProfileID = try await profileStore.activeProfileID()
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
            let profile = try await profileStore.createRemoteProfile(
                name: name,
                subscriptionURL: url,
                validator: validator
            )
            profiles = try await profileStore.profiles()
            if activate {
                try await performActivateProfile(profile.id)
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

    func confirmPendingSubscriptionImport(_ request: SubscriptionImportRequest) async {
        guard pendingSubscriptionImport == request else { return }
        pendingSubscriptionImport = nil

        do {
            try await addRemoteProfile(name: request.name, url: request.url, activate: false)
            selection = .profiles
            errorMessage = nil
        } catch {
            let message = redactedSubscriptionMessage(
                error.localizedDescription,
                url: request.url
            )
            errorMessage = message
            appendSupervisorLog("Confirmed subscription import failed: \(message)")
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

    func exportBackup() async {
        guard begin(.exportBackup) else { return }
        defer { end(.exportBackup) }
        guard let profileLayout else {
            errorMessage = "The application state directory is unavailable."
            return
        }

        let panel = NSSavePanel()
        panel.title = "Export MClash Backup"
        panel.prompt = "Export"
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "MClash-\(Date().ISO8601Format().prefix(10)).mclashbackup"
        guard panel.runModal() == .OK, let destinationURL = panel.url else { return }

        do {
            try await profileBackupService.exportBackup(
                from: profileLayout,
                to: destinationURL
            )
            errorMessage = nil
        } catch {
            recordOperationFailure(error, context: "Backup export")
        }
    }

    func restoreBackup() async {
        guard begin(.restoreBackup) else { return }
        defer { end(.restoreBackup) }
        guard let profileLayout, let profileStore else {
            errorMessage = "The application state directory is unavailable."
            return
        }

        let panel = NSOpenPanel()
        panel.title = "Restore MClash Backup"
        panel.prompt = "Restore"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let backupURL = panel.url else { return }

        let shouldReconnect = isConnected || isBusy
        let shouldRestoreSystemProxy = systemProxyEnabled
        if shouldReconnect, !(await performDisconnect()) { return }

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
        } catch {
            recordOperationFailure(error, context: "Backup restore")
            if shouldReconnect, activeConfigURL != nil {
                _ = await performConnect()
                if isConnected, shouldRestoreSystemProxy {
                    await performEnableSystemProxy()
                }
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
            await supervisor.stop()
            coreState = await supervisor.state()
            stopControllerStreams()

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
                failures.append("The candidate core could not be stopped safely because macOS proxy settings were not restored.")
                return failures
            }
        } else {
            await supervisor.stop()
            coreState = await supervisor.state()
            stopControllerStreams()
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

    func refreshProfile(_ id: ProfileID) async {
        guard begin(.refreshProfile(id)) else { return }
        defer { end(.refreshProfile(id)) }

        await performRefreshProfile(id)
    }

    func refreshAllProfiles() async {
        guard begin(.refreshAllProfiles) else { return }
        defer { end(.refreshAllProfiles) }

        guard let profileStore else { return }
        do {
            let ids = try await profileStore.remoteProfileIDs()
            for id in ids {
                try Task.checkCancellation()
                await performRefreshProfile(id)
            }
        } catch is CancellationError {
            return
        } catch {
            recordOperationFailure(error, context: "Subscription refresh")
        }
    }

    private func performRefreshProfile(_ id: ProfileID) async {

        guard let profileStore else { return }
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
                return
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
                await performRefreshProfile(id)
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
        await supervisor.stop()
        coreState = await supervisor.state()
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

    func refreshRules() async {
        guard begin(.refreshRules) else { return }
        defer { end(.refreshRules) }

        guard let apiClient else { return }
        await loadRules(using: apiClient, generation: controllerGeneration)
    }

    func refreshProviders() async {
        guard begin(.refreshProviders) else { return }
        defer { end(.refreshProviders) }

        guard let apiClient else { return }
        await loadProviders(using: apiClient, generation: controllerGeneration)
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
        } catch {
            guard generation == controllerGeneration else { return }
            providersErrorMessage = error.localizedDescription
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
        } catch {
            guard generation == controllerGeneration else { return }
            providersErrorMessage = error.localizedDescription
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
        } catch {
            guard generation == controllerGeneration else { return }
            providersErrorMessage = error.localizedDescription
            recordOperationFailure(error, context: "Rule provider update")
        }
    }

    func closeConnection(_ id: String) async {
        guard begin(.closeConnection(id)) else { return }
        defer { end(.closeConnection(id)) }

        guard let apiClient else { return }
        let generation = controllerGeneration
        do {
            try await apiClient.closeConnection(id: id)
            guard generation == controllerGeneration else { return }
            for _ in 0..<20
            where generation == controllerGeneration
                && connections?.connections.contains(where: { $0.id == id }) == true {
                try? await Task.sleep(for: .milliseconds(100))
            }
        } catch {
            guard generation == controllerGeneration else { return }
            recordOperationFailure(error, context: "Close connection")
        }
    }

    func closeAllConnections() async {
        guard begin(.closeAllConnections) else { return }
        defer { end(.closeAllConnections) }

        guard let apiClient else { return }
        let generation = controllerGeneration
        do {
            try await apiClient.closeAllConnections()
            guard generation == controllerGeneration else { return }
            for _ in 0..<20
            where generation == controllerGeneration
                && connections?.connections.isEmpty == false {
                try? await Task.sleep(for: .milliseconds(100))
            }
        } catch {
            guard generation == controllerGeneration else { return }
            recordOperationFailure(error, context: "Close all connections")
        }
    }

    func setNetworkCaptureEnabled(_ enabled: Bool) async {
        guard enabled != networkCapturePreferences.enabled else { return }
        do {
            try await applyNetworkCaptureRules(
                networkCapturePreferences.snapshot.rules,
                enabled: enabled,
                dnsEnabled: false
            )
        } catch {
            recordOperationFailure(error, context: "Network capture update")
        }
    }

    func applyNetworkCaptureRules(
        _ rules: [CaptureRule],
        enabled: Bool,
        dnsEnabled: Bool = false
    ) async throws {
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

        if enabled, systemProxyEnabled || hasSystemProxySnapshot {
            guard await performDisableSystemProxy() else {
                throw AppModelError.systemProxyRestoreFailed
            }
        }

        let previous = networkCapturePreferences
        let previousListener = networkExtensionMihomoListener
        let wasConnected = isConnected || isBusy
        do {
            if enabled, networkExtensionMihomoListener == nil {
                networkExtensionMihomoListener = try makeNetworkExtensionMihomoListener()
            }
            let candidate = try await store.replaceRules(
                rules,
                enabled: enabled,
                // DNS capture stays opt-in and is enabled only when a working
                // DNS data plane is packaged by the provider.
                dnsEnabled: enabled && dnsEnabled,
                failOpen: true
            )
            networkCapturePreferences = candidate
            if !enabled {
                networkExtensionMihomoListener = nil
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

            if wasConnected {
                guard await performConnect() else {
                    throw AppModelError.profileActivationFailed(
                        errorMessage ?? "The core could not restart with network capture settings."
                    )
                }
            } else {
                networkCaptureState = .off
            }
            appendSupervisorLog(
                enabled
                    ? "Per-application network capture is enabled."
                    : "Per-application network capture is disabled."
            )
        } catch {
            let primaryError = error
            do {
                networkExtensionMihomoListener = previous.enabled ? previousListener : nil
                networkCapturePreferences = try await store.replaceRules(
                    previous.snapshot.rules,
                    enabled: previous.enabled,
                    dnsEnabled: previous.dnsEnabled,
                    failOpen: previous.failOpen
                )
                if isConnected || isBusy {
                    _ = await performDisconnect()
                }
                let rollback = try await activateStoredProfile(
                    activeProfileID,
                    validator: try makeProfileValidator()
                )
                self.activeProfileID = rollback.profileID
                activeConfigURL = rollback.configurationURL
                if wasConnected { _ = await performConnect() }
            } catch {
                appendSupervisorLog(
                    "Network capture rollback failed: \(error.localizedDescription)"
                )
            }
            throw primaryError
        }
    }

    private func performNetworkCaptureActivation() async {
        guard networkCapturePreferences.enabled else {
            networkCaptureState = .off
            return
        }
        guard let listener = activeNetworkExtensionMihomoListener else {
            networkCaptureState = .failed("The private mihomo listener is unavailable.")
            return
        }
        networkCaptureState = .enabling
        do {
            try await localPortProbe.waitUntilListening(ports: [Int(listener.port)])
            let configuration = try NetworkExtensionRuntimeConfiguration(
                preferences: networkCapturePreferences,
                mihomoListener: listener
            )
            switch try await networkExtensionControl.enable(configuration) {
            case .running:
                networkCaptureState = .on(revision: configuration.revision)
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
            networkCaptureState = .failed(message)
            appendSupervisorLog("Network Extension activation failed: \(message)")
        }
    }

    @discardableResult
    private func performNetworkCaptureDeactivation() async -> Bool {
        networkCaptureState = .disabling
        do {
            try await networkExtensionControl.disable()
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
            guard generation == controllerGeneration, isConnected else {
                _ = await performDisableSystemProxy()
                return
            }
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
        _ preferences: SystemProxyPreferences
    ) async throws {
        guard begin(.changeSystemProxySettings) else {
            throw AppModelError.operationInProgress
        }
        defer { end(.changeSystemProxySettings) }
        guard let systemProxyPreferencesStore else {
            throw AppModelError.profileStoreUnavailable
        }

        let preferences = try preferences.validated()
        try await systemProxyPreferencesStore.save(preferences)
        systemProxyPreferences = preferences

        if systemProxyEnabled, let endpoints = currentSystemProxyEndpoints() {
            try await systemProxyManager.apply(
                endpoints: endpoints,
                bypassDomains: preferences.effectiveBypassDomains
            )
            startSystemProxyGuard(endpoints: endpoints)
        } else {
            systemProxyGuardTask?.cancel()
            systemProxyGuardTask = nil
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
            return
        }
        let interval = systemProxyPreferences.guardIntervalSeconds
        let bypassDomains = systemProxyPreferences.effectiveBypassDomains
        systemProxyGuardTask = Task { @MainActor [weak self] in
            var consecutiveFailures = 0
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(interval))
                } catch {
                    return
                }
                guard let self,
                      self.isConnected,
                      self.systemProxyState == .on else { return }
                do {
                    let matches = try await self.systemProxyManager.configurationMatches(
                        endpoints: endpoints,
                        bypassDomains: bypassDomains
                    )
                    if !matches {
                        try await self.systemProxyManager.apply(
                            endpoints: endpoints,
                            bypassDomains: bypassDomains
                        )
                        self.appendSupervisorLog(
                            "System proxy guard restored externally changed settings."
                        )
                    }
                    consecutiveFailures = 0
                } catch {
                    if consecutiveFailures == 0 {
                        self.appendSupervisorLog(
                            "System proxy guard could not verify settings: \(error.localizedDescription)"
                        )
                    }
                    consecutiveFailures += 1
                }
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
        trafficTask?.cancel()
        connectionsTask?.cancel()
        apiLogTask?.cancel()
        await supervisor.stop()
        stopControllerStreams()
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
        trafficTask?.cancel()
        connectionsTask?.cancel()
        apiLogTask?.cancel()
        await supervisor.stop()
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
        logs.removeAll(keepingCapacity: true)
    }

    func clearClosedConnectionHistory() {
        recentlyClosedConnections.removeAll(keepingCapacity: true)
    }

    private func recordClosedConnections(
        previous: MihomoConnectionSnapshot?,
        current: MihomoConnectionSnapshot?
    ) {
        guard let previous else { return }
        let currentIDs = Set(current?.connections.map(\.id) ?? [])
        let closed = previous.connections.filter { !currentIDs.contains($0.id) }
        guard !closed.isEmpty else { return }

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
        if controllerIsReady, isConnected, networkCapturePreferences.enabled {
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
        } catch {
            guard generation == controllerGeneration, isConnected else { return }
            rulesErrorMessage = error.localizedDescription
            appendSupervisorLog("Rules could not be loaded: \(error.localizedDescription)")
        }
    }

    private func loadProviders(using client: MihomoAPIClient, generation: Int) async {
        var failures: [String] = []

        do {
            let proxyCollection = try await client.fetchProxyProviders()
            guard generation == controllerGeneration, isConnected else { return }
            proxyProviders = proxyCollection.providers.values.sorted {
                $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
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
    }

    private func startControllerStreams(_ client: MihomoAPIClient, generation: Int) {
        cancelControllerStreamTasks()
        degradedStreams = []

        trafficTask = Task { [weak self] in
            await self?.monitorTraffic(client, generation: generation)
        }

        connectionsTask = Task { [weak self] in
            await self?.monitorConnections(client, generation: generation)
        }

        apiLogTask = Task { [weak self] in
            await self?.monitorLogs(client, generation: generation)
        }

        proxyRefreshTask = Task { [weak self] in
            await self?.monitorProxyState(client, generation: generation)
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
                markStreamDegraded(.proxies)
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
                markStreamDegraded(.traffic)
                appendSupervisorLog("Traffic stream interrupted: \(error.localizedDescription)")
                attempt += 1
                if !(await waitBeforeStreamRetry(attempt, generation: generation)) { return }
            }
        }
    }

    private func monitorConnections(_ client: MihomoAPIClient, generation: Int) async {
        var attempt = 0
        while streamShouldContinue(generation) {
            do {
                let stream = try await client.connectionStream()
                for try await snapshot in stream {
                    guard streamShouldContinue(generation) else { return }
                    applyConnectionSnapshot(snapshot, generation: generation)
                    markStreamHealthy(.connections)
                    attempt = 0
                }
                guard streamShouldContinue(generation) else { return }
                throw AppModelError.streamEnded("Connection")
            } catch is CancellationError {
                return
            } catch {
                guard streamShouldContinue(generation) else { return }
                markStreamDegraded(.connections)
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
                for try await entry in stream {
                    guard streamShouldContinue(generation) else { return }
                    markStreamHealthy(.logs)
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
                markStreamDegraded(.logs)
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
        guard degradedStreams.contains(stream) else { return }
        degradedStreams.remove(stream)
    }

    private func markStreamDegraded(_ stream: LiveStream) {
        guard !degradedStreams.contains(stream) else { return }
        degradedStreams.insert(stream)
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
        proxyProviders = []
        ruleProviders = []
        rulesErrorMessage = nil
        providersErrorMessage = nil
        degradedStreams = []
        connections = nil
        trafficAttribution.reset()
        routeTrafficEntries = []
        traffic = MihomoTraffic(upload: 0, download: 0, uploadTotal: 0, downloadTotal: 0)
        trafficHistory = []
    }

    private func cancelControllerStreamTasks() {
        trafficTask?.cancel()
        connectionsTask?.cancel()
        apiLogTask?.cancel()
        proxyRefreshTask?.cancel()
        trafficTask = nil
        connectionsTask = nil
        apiLogTask = nil
        proxyRefreshTask = nil
    }

    private func appendSupervisorLog(_ message: String) {
        appendCoreLog(CoreLogLine(stream: .supervisor, message: message))
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
        _ = trafficAttribution.ingest(
            connections: snapshot.connections,
            generation: generation
        )
        routeTrafficEntries = trafficAttribution.entries
        connections = MihomoConnectionSnapshot(
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
        logs.append(line)
        if logs.count > 1_500 {
            // Trim in batches so a noisy core does not shift the full observable array
            // for every line after reaching the display limit.
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
        case .enabling, .on, .disabling, .failed:
            true
        case .off, .requiresReboot:
            false
        }
    }

    private func makeNetworkExtensionMihomoListener() throws
        -> NetworkExtensionMihomoListenerConfiguration
    {
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
        return try NetworkExtensionMihomoListenerConfiguration(
            port: localPortProbe.availableTCPPort(),
            authentication: authentication
        )
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
    static let notificationsEnabledKey = "application.notificationsEnabled"
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
        }
    }
}
