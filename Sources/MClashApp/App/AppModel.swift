import AppKit
import Foundation
import Observation

@MainActor
@Observable
final class AppModel {
    struct TrafficSample: Identifiable, Equatable {
        let id = UUID()
        let timestamp: Date
        let download: Int64
        let upload: Int64
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
    }

    enum SystemProxyState: Equatable {
        case off
        case enabling
        case on
        case disabling
        case failed(String)
    }

    enum Operation: Hashable {
        case connection
        case importProfile
        case addRemoteProfile
        case activateProfile(ProfileID)
        case refreshProfile(ProfileID)
        case removeProfile(ProfileID)
        case changeMode
        case changeSystemProxy
        case selectProxy(String)
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
    var proxyGroups: [MihomoProxy] = []
    var proxiesByName: [String: MihomoProxy] = [:]
    var proxyDelays: [String: Int] = [:]
    var rules: [MihomoRule] = []
    var proxyProviders: [MihomoProxyProvider] = []
    var ruleProviders: [MihomoRuleProvider] = []
    var rulesErrorMessage: String?
    var providersErrorMessage: String?
    var traffic = MihomoTraffic(upload: 0, download: 0, uploadTotal: 0, downloadTotal: 0)
    var trafficHistory: [TrafficSample] = []
    var connections: MihomoConnectionSnapshot?
    var systemProxyState: SystemProxyState = .off
    var controllerState: ControllerState = .idle
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
    private let systemProxyManager: SystemProxyManager
    private let localPortProbe: LocalPortProbe
    private let preferenceDefaults: UserDefaults
    private var managedMixedPort: Int?
    private var apiClient: MihomoAPIClient?
    private var activeControllerEndpoint: URL?
    private var controllerSetupOperation: (id: UUID, endpoint: URL, task: Task<Void, Never>)?
    private var eventTask: Task<Void, Never>?
    private var trafficTask: Task<Void, Never>?
    private var connectionsTask: Task<Void, Never>?
    private var apiLogTask: Task<Void, Never>?
    private var controllerGeneration = 0
    private var systemProxyEnableOperation: (id: UUID, task: Task<Void, Never>)?
    private var systemProxyRestoreOperation: (id: UUID, task: Task<Bool, Never>)?
    private var crashProxyRestoreOperation: (id: UUID, task: Task<Bool, Never>)?
    private var shouldReenableSystemProxyAfterCrash = false
    private var prepared = false
    private(set) var preparationInProgress = false

    init(
        supervisor: CoreSupervisor = CoreSupervisor(),
        binaryLocator: CoreBinaryLocator = CoreBinaryLocator(),
        secretStore: any CoreSecretProviding = EphemeralCoreSecretProvider(),
        systemProxyManager: SystemProxyManager = SystemProxyManager(),
        localPortProbe: LocalPortProbe = LocalPortProbe(),
        profileDirectoryLayout: ProfileDirectoryLayout? = nil,
        profileStoreOverride: ProfileStore? = nil,
        preferenceDefaults: UserDefaults = .standard
    ) {
        self.supervisor = supervisor
        self.binaryLocator = binaryLocator
        self.secretStore = secretStore
        self.systemProxyManager = systemProxyManager
        self.localPortProbe = localPortProbe
        self.preferenceDefaults = preferenceDefaults
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

        if let layout = profileDirectoryLayout ?? (try? ProfileDirectoryLayout.applicationSupport()) {
            profileLayout = layout
            profileStore = profileStoreOverride ?? (try? ProfileStore(layout: layout))
        } else {
            profileLayout = nil
            profileStore = nil
        }

        eventTask = Task { [weak self, events = supervisor.events] in
            for await event in events {
                guard !Task.isCancelled else { break }
                self?.receive(event)
            }
        }
    }

    func prepare() async {
        guard !prepared, !preparationInProgress else { return }
        preparationInProgress = true
        defer { preparationInProgress = false }

        do {
            if let profileStore, let profileLayout {
                profiles = try await profileStore.profiles()
                activeProfileID = try await profileStore.activeProfileID()
                if activeProfileID != nil,
                   FileManager.default.fileExists(atPath: profileLayout.runtimeConfigurationURL.path) {
                    activeConfigURL = profileLayout.runtimeConfigurationURL
                }

                let snapshotURL = systemProxySnapshotURL(layout: profileLayout)
                if FileManager.default.fileExists(atPath: snapshotURL.path) {
                    guard await performDisableSystemProxy() else {
                        throw AppModelError.systemProxyRestoreFailed
                    }
                    appendSupervisorLog("Recovered system proxy settings left by an interrupted session.")
                }
            }
            prepared = true
        } catch {
            if hasSystemProxySnapshot {
                systemProxyState = .failed(error.localizedDescription)
            }
            errorMessage = error.localizedDescription
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
        case .on, .enabling, .disabling, .failed:
            true
        case .off:
            false
        }
    }

    var systemProxyRecoveryRequired: Bool {
        if case .failed = systemProxyState { return true }
        return false
    }

    var localHTTPProxyPort: Int? {
        guard let runtimeConfig else { return nil }
        return managedMixedPort
            ?? positivePort(runtimeConfig.port)
            ?? positivePort(runtimeConfig.mixedPort)
    }

    var localSOCKSProxyPort: Int? {
        guard let runtimeConfig else { return nil }
        return managedMixedPort
            ?? positivePort(runtimeConfig.socksPort)
            ?? positivePort(runtimeConfig.mixedPort)
    }

    var localHTTPProxyAddress: String? {
        localHTTPProxyPort.map { "127.0.0.1:\($0)" }
    }

    var localSOCKSProxyAddress: String? {
        localSOCKSProxyPort.map { "127.0.0.1:\($0)" }
    }

    var networkStateTransitionInProgress: Bool {
        if preparationInProgress { return true }
        if systemProxyRecoveryRequired { return true }
        if case .enabling = systemProxyState { return true }
        if case .disabling = systemProxyState { return true }
        return operations.contains { $0.serializesNetworkState || $0.isCoreBound }
    }

    func isPerforming(_ operation: Operation) -> Bool {
        operations.contains(operation)
    }

    func canPerform(_ operation: Operation) -> Bool {
        if preparationInProgress { return false }
        if systemProxyRecoveryRequired, operation != .changeSystemProxy { return false }
        if case .enabling = systemProxyState, operation != .changeSystemProxy { return false }
        if case .disabling = systemProxyState, operation != .changeSystemProxy { return false }
        if operations.contains(operation) { return false }
        if operation.serializesNetworkState {
            if operation == .connection {
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

    func addRemoteProfile(name: String, url: URL) async throws {
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
            try await performActivateProfile(profile.id)
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
            activation = try await profileStore.activateProfile(
                id,
                validator: AcceptingProfileValidator()
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
                    let rollback = try await profileStore.activateProfile(
                        previousProfileID,
                        validator: try makeProfileValidator()
                    )
                    activeProfileID = rollback.profileID
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

    func refreshProfile(_ id: ProfileID) async {
        guard begin(.refreshProfile(id)) else { return }
        defer { end(.refreshProfile(id)) }

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
        defer { end(.changeMode) }

        guard let apiClient else { return }
        let generation = controllerGeneration
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
        defer { end(.selectProxy(group)) }

        guard let apiClient else { return false }
        let generation = controllerGeneration
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

    func measureDelay(proxy: String, group: String? = nil) async -> Int? {
        guard begin(.measureDelay(proxy)) else { return nil }
        defer { end(.measureDelay(proxy)) }

        guard let apiClient,
              let target = delayTarget(forProxy: proxy, group: group) else {
            return nil
        }
        let expectedStatus = expectedDelayStatus(forProxy: proxy, group: group)
        let generation = controllerGeneration
        do {
            let delay = try await apiClient.measureDelay(
                proxy: proxy,
                targetURL: target,
                expectedStatus: expectedStatus
            )
            guard generation == controllerGeneration, isConnected else { return nil }
            proxyDelays[proxy] = delay
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
              let groupModel = proxyGroups.first(where: { $0.name == group }) else {
            return
        }
        let target = delayTarget(for: groupModel) ?? defaultDelayTarget
        let expectedStatus = normalizedExpectedStatus(groupModel.expectedStatus)
        let generation = controllerGeneration
        do {
            let delays = try await apiClient.measureGroupDelays(
                group: group,
                targetURL: target,
                expectedStatus: expectedStatus
            )
            guard generation == controllerGeneration, isConnected else { return }
            proxyDelays.merge(delays) { _, new in new }
        } catch {
            guard generation == controllerGeneration else { return }
            recordOperationFailure(error, context: "Group latency test")
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

    func toggleSystemProxy() async {
        guard begin(.changeSystemProxy) else { return }
        defer { end(.changeSystemProxy) }

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
        defer { end(.changeSystemProxy) }

        if enabled {
            await performEnableSystemProxy()
        } else {
            shouldReenableSystemProxyAfterCrash = false
            await performDisableSystemProxy()
        }
    }

    func enableSystemProxy() async {
        guard begin(.changeSystemProxy) else { return }
        defer { end(.changeSystemProxy) }
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
                savingSnapshotTo: snapshotURL
            )
            guard generation == controllerGeneration, isConnected else {
                _ = await performDisableSystemProxy()
                return
            }
            systemProxyState = .on
            appendSupervisorLog(
                "System proxy enabled: HTTP 127.0.0.1:\(httpPort), SOCKS5 127.0.0.1:\(socksPort)."
            )
        } catch {
            let message = error.localizedDescription
            systemProxyState = .failed(message)
            if hasSystemProxySnapshot {
                _ = await performDisableSystemProxy()
            }
            errorMessage = message
            appendSupervisorLog("System proxy could not be enabled: \(message)")
        }
    }

    func disableSystemProxy() async {
        guard begin(.changeSystemProxy) else { return }
        defer { end(.changeSystemProxy) }
        shouldReenableSystemProxyAfterCrash = false
        await performDisableSystemProxy()
    }

    @discardableResult
    private func performDisableSystemProxy() async -> Bool {
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
        shouldReenableSystemProxyAfterCrash = false
        if let operation = systemProxyEnableOperation {
            await operation.task.value
        }
        if systemProxyEnabled || hasSystemProxySnapshot {
            guard await performDisableSystemProxy() else { return false }
        }
        trafficTask?.cancel()
        connectionsTask?.cancel()
        apiLogTask?.cancel()
        await supervisor.stop()
        stopControllerStreams()
        return true
    }

    func clearLogs() {
        logs.removeAll(keepingCapacity: true)
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
                let shouldReenable = systemProxyEnabled
                stopControllerStreams()
                if shouldReenable || hasSystemProxySnapshot {
                    beginCrashSystemProxyRestore(reenableAfterRestart: shouldReenable)
                }
            }
            if case .stopped = state {
                shouldReenableSystemProxyAfterCrash = false
                stopControllerStreams()
                if systemProxyEnabled || hasSystemProxySnapshot {
                    Task { [weak self] in await self?.performDisableSystemProxy() }
                }
            }
            if case let .running(session) = state {
                Task { [weak self] in await self?.handleRunningSession(session) }
            }
        case let .log(line):
            logs.append(line)
            if logs.count > 1_500 {
                logs.removeFirst(logs.count - 1_500)
            }
        }
    }

    private func handleRunningSession(_ session: CoreSession) async {
        await controllerDidStart(session)
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
            applyProxyCollection(proxies)
            startControllerStreams(client, generation: generation)
            controllerState = .ready
            errorMessage = nil
            appendSupervisorLog("Connected to the local Alpha controller.")
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
        if let ports = resolvedProxyPorts(in: initialConfig) {
            do {
                try await localPortProbe.waitUntilListening(ports: Set([ports.http, ports.socks]))
                return initialConfig
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                appendSupervisorLog(
                    "Configured proxy listeners were unavailable; applying a temporary MClash mixed port."
                )
            }
        } else {
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
                try await localPortProbe.waitUntilListening(ports: [port])
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

    private func refreshProxyGroups(generation: Int) async {
        guard let apiClient else { return }
        do {
            let proxies = try await apiClient.fetchProxies()
            guard generation == controllerGeneration, isConnected else { return }
            applyProxyCollection(proxies)
        } catch {
            guard generation == controllerGeneration, isConnected else { return }
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
                    degradedStreams.remove(.traffic)
                    attempt = 0
                }
                guard streamShouldContinue(generation) else { return }
                throw AppModelError.streamEnded("Traffic")
            } catch is CancellationError {
                return
            } catch {
                guard streamShouldContinue(generation) else { return }
                degradedStreams.insert(.traffic)
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
                    connections = MihomoConnectionSnapshot(
                        downloadTotal: snapshot.downloadTotal,
                        uploadTotal: snapshot.uploadTotal,
                        connections: snapshot.connections.sorted {
                            if $0.start == $1.start { return $0.id < $1.id }
                            return $0.start > $1.start
                        },
                        memory: snapshot.memory
                    )
                    degradedStreams.remove(.connections)
                    attempt = 0
                }
                guard streamShouldContinue(generation) else { return }
                throw AppModelError.streamEnded("Connection")
            } catch is CancellationError {
                return
            } catch {
                guard streamShouldContinue(generation) else { return }
                degradedStreams.insert(.connections)
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
                    degradedStreams.remove(.logs)
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
                degradedStreams.insert(.logs)
                appendSupervisorLog("Log stream interrupted: \(error.localizedDescription)")
                attempt += 1
                if !(await waitBeforeStreamRetry(attempt, generation: generation)) { return }
            }
        }
    }

    private func streamShouldContinue(_ generation: Int) -> Bool {
        !Task.isCancelled && generation == controllerGeneration && isConnected
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
        apiClient = nil
        activeControllerEndpoint = nil
        controllerState = .idle
        runtimeConfig = nil
        managedMixedPort = nil
        proxyGroups = []
        proxiesByName = [:]
        proxyDelays = [:]
        rules = []
        proxyProviders = []
        ruleProviders = []
        rulesErrorMessage = nil
        providersErrorMessage = nil
        degradedStreams = []
        connections = nil
        traffic = MihomoTraffic(upload: 0, download: 0, uploadTotal: 0, downloadTotal: 0)
        trafficHistory = []
    }

    private func cancelControllerStreamTasks() {
        trafficTask?.cancel()
        connectionsTask?.cancel()
        apiLogTask?.cancel()
        trafficTask = nil
        connectionsTask = nil
        apiLogTask = nil
    }

    private func appendSupervisorLog(_ message: String) {
        appendCoreLog(CoreLogLine(stream: .supervisor, message: message))
    }

    private func applyProxyCollection(_ collection: MihomoProxyCollection) {
        proxiesByName = collection.proxies
        let currentNames = Set(collection.proxies.keys)
        proxyDelays = proxyDelays.filter { currentNames.contains($0.key) }
        proxyGroups = collection.proxies.values
            .filter { !$0.all.isEmpty && !$0.hidden }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        for proxy in collection.proxies.values {
            if let delay = proxy.history.last?.delay, delay > 0 {
                proxyDelays[proxy.name] = delay
            }
        }
    }

    private func delayTarget(forProxy proxy: String, group groupName: String?) -> URL? {
        if let proxyModel = proxiesByName[proxy], let target = delayTarget(for: proxyModel) {
            return target
        }
        if let groupName,
           let group = proxyGroups.first(where: { $0.name == groupName }),
           let target = delayTarget(for: group) {
            return target
        }
        if let group = proxyGroups.first(where: { $0.all.contains(proxy) }),
           let target = delayTarget(for: group) {
            return target
        }
        return defaultDelayTarget
    }

    private func expectedDelayStatus(forProxy proxy: String, group groupName: String?) -> String? {
        if let status = normalizedExpectedStatus(proxiesByName[proxy]?.expectedStatus) {
            return status
        }
        if let groupName,
           let group = proxyGroups.first(where: { $0.name == groupName }),
           let status = normalizedExpectedStatus(group.expectedStatus) {
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
            logs.removeFirst(logs.count - 1_500)
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

    private var hasSystemProxySnapshot: Bool {
        guard let profileLayout else { return false }
        return FileManager.default.fileExists(
            atPath: systemProxySnapshotURL(layout: profileLayout).path
        )
    }

    static let autoEnableSystemProxyKey = "network.autoEnableSystemProxy"
    static let closeConnectionsOnRoutingChangeKey = "network.closeConnectionsOnRoutingChange"
}

private extension AppModel.Operation {
    var serializesNetworkState: Bool {
        switch self {
        case .connection,
             .importProfile,
             .addRemoteProfile,
             .activateProfile,
             .refreshProfile,
             .removeProfile,
             .changeSystemProxy:
            true
        case .changeMode,
             .selectProxy,
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
             .activateProfile,
             .refreshProfile,
             .removeProfile,
             .changeSystemProxy:
            false
        }
    }
}

private enum AppModelError: LocalizedError {
    case profileStoreUnavailable
    case operationInProgress
    case streamEnded(String)
    case systemProxyRestoreFailed
    case profileActivationFailed(String)
    case localProxyPortsUnavailable
    case localProxyOverrideRejected(Int)

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
        case let .profileActivationFailed(message):
            message
        case .localProxyPortsUnavailable:
            "The active profile does not expose both an HTTP and a SOCKS5 local proxy port. Add port/socks-port or mixed-port to the profile."
        case let .localProxyOverrideRejected(port):
            "mihomo did not accept MClash's temporary local proxy port \(port)."
        }
    }
}
