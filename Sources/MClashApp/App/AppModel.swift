import AppKit
import Foundation
import Observation

@MainActor
@Observable
final class AppModel {
    enum Destination: String, CaseIterable, Identifiable {
        case overview
        case proxies
        case profiles
        case connections
        case logs
        case settings

        var id: Self { self }

        var title: String {
            switch self {
            case .overview: "Overview"
            case .proxies: "Proxies"
            case .profiles: "Profiles"
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
            case .connections: "arrow.left.arrow.right"
            case .logs: "text.alignleft"
            case .settings: "gearshape"
            }
        }
    }

    var selection: Destination? = .overview
    var coreState: CoreRunState = .stopped
    var activeConfigURL: URL?
    var explicitCoreURL: URL?
    var logs: [CoreLogLine] = []
    var errorMessage: String?
    var profiles: [ProfileMetadata] = []
    var activeProfileID: ProfileID?
    var runtimeConfig: MihomoConfig?
    var proxyGroups: [MihomoProxy] = []
    var traffic = MihomoTraffic(upload: 0, download: 0, uploadTotal: 0, downloadTotal: 0)
    var connections: MihomoConnectionSnapshot?
    var systemProxyEnabled = false

    private let supervisor: CoreSupervisor
    private let binaryLocator: CoreBinaryLocator
    private let secretStore: any CoreSecretProviding
    private let profileStore: ProfileStore?
    private let profileLayout: ProfileDirectoryLayout?
    private let systemProxyManager: SystemProxyManager
    private var apiClient: MihomoAPIClient?
    private var activeControllerEndpoint: URL?
    private var eventTask: Task<Void, Never>?
    private var trafficTask: Task<Void, Never>?
    private var connectionsTask: Task<Void, Never>?
    private var apiLogTask: Task<Void, Never>?
    private var prepared = false

    init(
        supervisor: CoreSupervisor = CoreSupervisor(),
        binaryLocator: CoreBinaryLocator = CoreBinaryLocator(),
        secretStore: any CoreSecretProviding = CoreSecretStore(),
        systemProxyManager: SystemProxyManager = SystemProxyManager()
    ) {
        self.supervisor = supervisor
        self.binaryLocator = binaryLocator
        self.secretStore = secretStore
        self.systemProxyManager = systemProxyManager

        if let layout = try? ProfileDirectoryLayout.applicationSupport() {
            profileLayout = layout
            profileStore = try? ProfileStore(layout: layout)
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
        guard !prepared else { return }
        prepared = true

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
                    try await systemProxyManager.restoreSnapshot(from: snapshotURL)
                    try FileManager.default.removeItem(at: snapshotURL)
                    appendSupervisorLog("Recovered system proxy settings left by an interrupted session.")
                }
            }
        } catch {
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

    func chooseConfiguration() {
        let panel = NSOpenPanel()
        panel.title = "Choose a mihomo configuration"
        panel.prompt = "Use Configuration"
        panel.allowedContentTypes = [.yaml]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false

        if panel.runModal() == .OK {
            activeConfigURL = panel.url
            errorMessage = nil
        }
    }

    func importProfile() async {
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
            try await activateProfile(profile.id)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func addRemoteProfile(name: String, url: URL) async {
        guard let profileStore else {
            errorMessage = "The profile store could not be initialized."
            return
        }

        do {
            let validator = try makeProfileValidator()
            let profile = try await profileStore.createRemoteProfile(
                name: name,
                subscriptionURL: url,
                validator: validator
            )
            profiles = try await profileStore.profiles()
            try await activateProfile(profile.id)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func activateProfile(_ id: ProfileID) async throws {
        guard let profileStore else {
            throw AppModelError.profileStoreUnavailable
        }

        if isConnected || isBusy {
            await disconnect()
        }

        let activation = try await profileStore.activateProfile(
            id,
            validator: try makeProfileValidator()
        )
        activeProfileID = activation.profileID
        activeConfigURL = activation.configurationURL
        profiles = try await profileStore.profiles()
        errorMessage = nil
    }

    func refreshProfile(_ id: ProfileID) async {
        guard let profileStore else { return }
        do {
            _ = try await profileStore.refreshRemoteProfile(
                id,
                validator: try makeProfileValidator()
            )
            profiles = try await profileStore.profiles()
            if activeProfileID == id {
                try await activateProfile(id)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func chooseCoreBinary() {
        let panel = NSOpenPanel()
        panel.title = "Choose the mihomo Alpha binary"
        panel.prompt = "Use Core"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false

        if panel.runModal() == .OK {
            explicitCoreURL = panel.url
            errorMessage = nil
        }
    }

    func toggleConnection() async {
        if isConnected || isBusy {
            await supervisor.stop()
        } else {
            await connect()
        }
    }

    func connect() async {
        guard let activeConfigURL else {
            chooseConfiguration()
            guard self.activeConfigURL != nil else { return }
            await connect()
            return
        }

        do {
            errorMessage = nil
            let binaryURL = try binaryLocator.locate(explicitURL: explicitCoreURL)
            let secret = try secretStore.loadOrCreate()
            let homeDirectory = try coreHomeDirectory()
            let configuration = CoreLaunchConfiguration(
                binaryURL: binaryURL,
                homeDirectory: homeDirectory,
                configURL: activeConfigURL,
                controllerPort: 19_090,
                secret: secret
            )
            try await supervisor.start(configuration)
            let state = await supervisor.state()
            coreState = state
            if case let .running(session) = state {
                await controllerDidStart(session)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func disconnect() async {
        if systemProxyEnabled {
            await disableSystemProxy()
        }
        await supervisor.stop()
        coreState = await supervisor.state()
        stopControllerStreams()
    }

    func setMode(_ mode: String) async {
        guard let apiClient else { return }
        do {
            try await apiClient.patchConfig(MihomoConfigPatch(mode: mode))
            runtimeConfig = try await apiClient.fetchConfig()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func selectProxy(group: String, proxy: String) async {
        guard let apiClient else { return }
        do {
            try await apiClient.selectProxy(group: group, proxy: proxy)
            await refreshProxyGroups()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func measureDelay(proxy: String) async -> Int? {
        guard let apiClient,
              let target = URL(string: "https://www.gstatic.com/generate_204") else {
            return nil
        }
        do {
            return try await apiClient.measureDelay(proxy: proxy, targetURL: target)
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    func closeConnection(_ id: String) async {
        guard let apiClient else { return }
        do {
            try await apiClient.closeConnection(id: id)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func closeAllConnections() async {
        guard let apiClient else { return }
        do {
            try await apiClient.closeAllConnections()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func toggleSystemProxy() async {
        if systemProxyEnabled {
            await disableSystemProxy()
        } else {
            await enableSystemProxy()
        }
    }

    func enableSystemProxy() async {
        guard isConnected, let mixedPort = runtimeConfig?.mixedPort, mixedPort > 0 else {
            errorMessage = "Connect the core with a configuration that exposes a mixed port first."
            return
        }
        guard let profileLayout else {
            errorMessage = "The application state directory is unavailable."
            return
        }

        do {
            let endpoints = try LocalSystemProxyEndpoints(mixedPort: mixedPort)
            let snapshotURL = systemProxySnapshotURL(layout: profileLayout)
            try await systemProxyManager.activate(
                endpoints: endpoints,
                savingSnapshotTo: snapshotURL
            )
            systemProxyEnabled = true
            appendSupervisorLog("System proxy enabled on 127.0.0.1:\(mixedPort).")
        } catch {
            let snapshotURL = systemProxySnapshotURL(layout: profileLayout)
            if FileManager.default.fileExists(atPath: snapshotURL.path) {
                try? await systemProxyManager.restoreSnapshot(from: snapshotURL)
                try? FileManager.default.removeItem(at: snapshotURL)
            }
            systemProxyEnabled = false
            errorMessage = error.localizedDescription
        }
    }

    func disableSystemProxy() async {
        guard let profileLayout else { return }
        let snapshotURL = systemProxySnapshotURL(layout: profileLayout)

        do {
            if FileManager.default.fileExists(atPath: snapshotURL.path) {
                try await systemProxyManager.restoreSnapshot(from: snapshotURL)
                try FileManager.default.removeItem(at: snapshotURL)
            }
            systemProxyEnabled = false
            appendSupervisorLog("System proxy restored to its previous state.")
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func shutdown() async {
        trafficTask?.cancel()
        connectionsTask?.cancel()
        apiLogTask?.cancel()
        if systemProxyEnabled {
            await disableSystemProxy()
        }
        await supervisor.stop()
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
                stopControllerStreams()
                if systemProxyEnabled {
                    Task { [weak self] in await self?.disableSystemProxy() }
                }
            }
            if case let .running(session) = state {
                Task { [weak self] in await self?.controllerDidStart(session) }
            }
        case let .log(line):
            logs.append(line)
            if logs.count > 1_500 {
                logs.removeFirst(logs.count - 1_500)
            }
        }
    }

    private func coreHomeDirectory() throws -> URL {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "MClash", directoryHint: .isDirectory)
            .appending(path: "CoreHome", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        return root
    }

    private func makeProfileValidator() throws -> ClosureProfileValidator {
        let binaryURL = try binaryLocator.locate(explicitURL: explicitCoreURL)
        let homeDirectory = try coreHomeDirectory()
        let secret = try secretStore.loadOrCreate()

        return ClosureProfileValidator { [supervisor] configurationURL in
            try await supervisor.validate(
                CoreLaunchConfiguration(
                    binaryURL: binaryURL,
                    homeDirectory: homeDirectory,
                    configURL: configurationURL,
                    controllerPort: 19_090,
                    secret: secret
                )
            )
        }
    }

    private func controllerDidStart(_ session: CoreSession) async {
        do {
            let client = try MihomoAPIClient(baseURL: session.endpoint, secret: session.secret)
            apiClient = client
            activeControllerEndpoint = session.endpoint
            runtimeConfig = try await client.fetchConfig()
            let proxies = try await client.fetchProxies()
            proxyGroups = proxies.proxies.values
                .filter { !$0.all.isEmpty && !$0.hidden }
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            startControllerStreams(client)
            appendSupervisorLog("Connected to the local Alpha controller.")
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func refreshProxyGroups() async {
        guard let apiClient else { return }
        do {
            let proxies = try await apiClient.fetchProxies()
            proxyGroups = proxies.proxies.values
                .filter { !$0.all.isEmpty && !$0.hidden }
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func startControllerStreams(_ client: MihomoAPIClient) {
        cancelControllerStreamTasks()

        trafficTask = Task { [weak self] in
            do {
                let stream = try await client.trafficStream()
                for try await sample in stream where !Task.isCancelled {
                    self?.traffic = sample
                }
            } catch is CancellationError {
                return
            } catch {
                self?.appendSupervisorLog("Traffic stream ended: \(error.localizedDescription)")
            }
        }

        connectionsTask = Task { [weak self] in
            do {
                let stream = try await client.connectionStream()
                for try await snapshot in stream where !Task.isCancelled {
                    self?.connections = snapshot
                }
            } catch is CancellationError {
                return
            } catch {
                self?.appendSupervisorLog("Connection stream ended: \(error.localizedDescription)")
            }
        }

        apiLogTask = Task { [weak self] in
            do {
                let stream = try await client.logStream(minimumLevel: .info)
                for try await entry in stream where !Task.isCancelled {
                    self?.logs.append(
                        CoreLogLine(stream: .standardOutput, message: "[\(entry.type)] \(entry.payload)")
                    )
                }
            } catch is CancellationError {
                return
            } catch {
                self?.appendSupervisorLog("Log stream ended: \(error.localizedDescription)")
            }
        }
    }

    private func stopControllerStreams() {
        cancelControllerStreamTasks()
        apiClient = nil
        activeControllerEndpoint = nil
        runtimeConfig = nil
        proxyGroups = []
        connections = nil
        traffic = MihomoTraffic(upload: 0, download: 0, uploadTotal: 0, downloadTotal: 0)
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
        logs.append(CoreLogLine(stream: .supervisor, message: message))
    }

    private func systemProxySnapshotURL(layout: ProfileDirectoryLayout) -> URL {
        layout.stateDirectory.appending(path: "system-proxy-snapshot.json")
    }
}

private enum AppModelError: LocalizedError {
    case profileStoreUnavailable

    var errorDescription: String? {
        "The MClash profile store is unavailable."
    }
}
