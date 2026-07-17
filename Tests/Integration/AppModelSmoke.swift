import Darwin
import Foundation

@main
struct AppModelSmoke {
    @MainActor
    static func main() async throws {
        let repository = URL(filePath: FileManager.default.currentDirectoryPath)
        guard let corePath = ProcessInfo.processInfo.environment["MCLASH_TEST_CORE"] else {
            throw SmokeFailure.corePathMissing
        }
        let coreURL = URL(filePath: corePath)
        let locator = CoreBinaryLocator(
            environment: [:],
            applicationSupportDirectory: repository.appending(path: ".build/unused-core-support"),
            bundledBinaryURLs: [coreURL]
        )
        let stateRoot = FileManager.default.temporaryDirectory.appending(
            path: "mclash-app-smoke-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        let layout = ProfileDirectoryLayout(rootDirectory: stateRoot)
        try layout.createDirectories()
        defer { try? FileManager.default.removeItem(at: stateRoot) }

        let preferencesSuiteName = "MClash.AppModelSmoke.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: preferencesSuiteName) else {
            throw SmokeFailure.preferencesUnavailable
        }
        defaults.set(false, forKey: AppModel.autoEnableSystemProxyKey)
        defer { defaults.removePersistentDomain(forName: preferencesSuiteName) }

        let profileStore = try ProfileStore(layout: layout)
        let startupProfile = try await profileStore.importProfile(
            from: repository.appending(path: "Tests/Fixtures/minimal.yaml"),
            name: "Startup profile"
        )
        _ = try await profileStore.activateProfile(
            startupProfile.id,
            validator: AcceptingProfileValidator()
        )

        let systemProxyBackend = try IsolatedSystemProxyBackend()
        let model = AppModel(
            binaryLocator: locator,
            secretStore: StaticSecretProvider(),
            systemProxyManager: SystemProxyManager(backend: systemProxyBackend),
            profileDirectoryLayout: layout,
            profileStoreOverride: profileStore,
            preferenceDefaults: defaults
        )

        do {
            await model.prepare()

            for _ in 0..<30 where !model.isConnected || model.runtimeConfig == nil {
                try await Task.sleep(for: .milliseconds(100))
            }

            guard model.isConnected,
                  model.runningSession?.version.hasPrefix("alpha-") == true,
                  model.runtimeConfig?.mixedPort == 17_890,
                  model.localHTTPListenerPort == nil,
                  model.localSOCKSListenerPort == nil,
                  model.localMixedListenerPort == 17_890,
                  model.localHTTPProxyPort == 17_890,
                  model.localSOCKSProxyPort == 17_890,
                  model.localListenerEndpoints == [
                      AppModel.LocalListenerEndpoint(
                          kind: .mixed,
                          host: "127.0.0.1",
                          port: 17_890,
                          source: .profile
                      )
                  ],
                  model.systemProxyState == .off else {
                let details = [
                    "state=\(String(describing: model.coreState))",
                    "error=\(model.errorMessage ?? "none")",
                    "runtime=\(model.runtimeConfig?.mixedPort.description ?? "none")",
                    "lastLog=\(model.logs.last?.message ?? "none")"
                ].joined(separator: ", ")
                throw SmokeFailure.didNotConnect(details)
            }

            try verifyProxyProtocols(model: model)

            for _ in 0..<100 where !model.canPerform(.changeSystemProxy) {
                try await Task.sleep(for: .milliseconds(50))
            }
            await model.enableSystemProxy()
            guard model.systemProxyState == .on,
                  systemProxyBackend.applyCount == 1,
                  model.runningSession?.startedAt != nil else {
                throw SmokeFailure.isolatedSystemProxyDidNotEnable(
                    "state=\(model.systemProxyState), "
                        + "applyCount=\(systemProxyBackend.applyCount), "
                        + "canChange=\(model.canPerform(.changeSystemProxy)), "
                        + "preparing=\(model.preparationInProgress), "
                        + "operations=\(model.operations), "
                        + "error=\(model.errorMessage ?? "none")"
                )
            }

            let requestedMixedPort = try LocalPortProbe().availableTCPPort()
            let runtimeApplyOutcome = try await model.applyRuntimeOverrides(
                RuntimeOverrides(
                    ports: RuntimePortOverrides(mixedPort: requestedMixedPort)
                )
            )
            guard runtimeApplyOutcome == .savedAndRestarted,
                  model.runtimeSettingsApplyState == .completed(.savedAndRestarted),
                  model.isConnected,
                  model.controllerIsReady,
                  model.systemProxyState == .on,
                  model.localMixedListenerPort == requestedMixedPort,
                  model.localHTTPProxyPort == requestedMixedPort,
                  model.localSOCKSProxyPort == requestedMixedPort,
                  model.localListenerEndpoints.first?.source == .override,
                  let successfulSettingsStartedAt = model.runningSession?.startedAt else {
                throw SmokeFailure.runtimeSettingsDidNotRestart(
                    model.errorMessage ?? "No additional error was reported."
                )
            }

            let unchangedOutcome = try await model.applyRuntimeOverrides(model.runtimeOverrides)
            guard unchangedOutcome == .unchanged,
                  model.runtimeSettingsApplyState == .completed(.unchanged),
                  model.runningSession?.startedAt == successfulSettingsStartedAt else {
                throw SmokeFailure.unchangedRuntimeSettingsRestarted
            }

            let previousOverrides = model.runtimeOverrides
            let previousRuntime = try Data(contentsOf: layout.runtimeConfigurationURL)
            let occupiedPort = try OccupiedTCPPort()
            do {
                _ = try await model.applyRuntimeOverrides(
                    RuntimeOverrides(
                        ports: RuntimePortOverrides(mixedPort: occupiedPort.port)
                    )
                )
                throw SmokeFailure.occupiedRuntimePortWasAccepted
            } catch let error as SmokeFailure {
                throw error
            } catch {
                // The candidate must fail its protocol readiness check and the
                // model must restore every durable and live network surface.
            }
            let persistedOverrides = try await RuntimeOverrideStore(profileLayout: layout).load()
            guard model.runtimeOverrides == previousOverrides,
                  persistedOverrides == previousOverrides,
                  try Data(contentsOf: layout.runtimeConfigurationURL) == previousRuntime,
                  model.isConnected,
                  model.controllerIsReady,
                  model.systemProxyState == .on,
                  model.localMixedListenerPort == requestedMixedPort,
                  case .failed = model.runtimeSettingsApplyState,
                  let startedAt = model.runningSession?.startedAt,
                  startedAt != successfulSettingsStartedAt else {
                throw SmokeFailure.runtimeSettingsRollbackFailed(
                    model.errorMessage ?? "No additional error was reported."
                )
            }

            let corePID = try processID(containing: layout.rootDirectory.path)
            guard Darwin.kill(corePID, SIGKILL) == 0 else {
                throw SmokeFailure.coreTerminationFailed(errno)
            }

            for _ in 0..<180 {
                if model.isConnected,
                   model.controllerIsReady,
                   model.systemProxyState == .on,
                   model.runningSession?.startedAt != startedAt,
                   systemProxyBackend.applyCount >= 3 {
                    break
                }
                try await Task.sleep(for: .milliseconds(100))
            }

            guard model.isConnected,
                  model.controllerIsReady,
                  model.systemProxyState == .on,
                  model.runningSession?.startedAt != startedAt,
                  systemProxyBackend.applyCount >= 3 else {
                throw SmokeFailure.crashRecoveryDidNotRestoreSystemProxy(
                    model.errorMessage ?? "No additional error was reported."
                )
            }

            try verifyProxyProtocols(model: model)

            await model.disconnect()
            guard !model.isConnected else { throw SmokeFailure.didNotDisconnect }

            _ = try await model.resetRuntimeOverrides()

            model.activeConfigURL = repository.appending(path: "Tests/Fixtures/no-listener.yaml")
            await model.connect()

            guard model.isConnected,
                  model.controllerIsReady,
                  let managedPort = model.runtimeConfig?.mixedPort,
                  managedPort > 0,
                  model.localMixedListenerPort == managedPort,
                  model.localHTTPProxyPort == managedPort,
                  model.localSOCKSProxyPort == managedPort,
                  model.localListenerEndpoints.first(where: { $0.kind == .mixed })?.source
                    == .managedFallback,
                  model.systemProxyState == .off else {
                throw SmokeFailure.runtimeListenerWasNotCreated(
                    model.errorMessage ?? "No additional error was reported."
                )
            }

            try verifyProxyProtocols(model: model)

            await model.disconnect()
            guard !model.isConnected else { throw SmokeFailure.didNotDisconnect }

            print("App model HTTP/SOCKS, runtime-listener, and crash-recovery smoke passed")
        } catch {
            await model.shutdown()
            throw error
        }
    }

    @MainActor
    private static func verifyProxyProtocols(model: AppModel) throws {
        guard let target = ProcessInfo.processInfo.environment["MCLASH_PROXY_SMOKE_URL"],
              let httpPort = model.localHTTPProxyPort,
              let socksPort = model.localSOCKSProxyPort else {
            throw SmokeFailure.proxyTestConfigurationUnavailable
        }

        try runCurl([
            "--noproxy", "", "--fail", "--silent", "--show-error", "--max-time", "10",
            "--proxy", "http://127.0.0.1:\(httpPort)", target
        ])
        try runCurl([
            "--noproxy", "", "--fail", "--silent", "--show-error", "--max-time", "10",
            "--socks5-hostname", "127.0.0.1:\(socksPort)", target
        ])
    }

    private static func runCurl(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/curl")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw SmokeFailure.proxyRequestFailed(process.terminationStatus)
        }
    }

    private static func processID(containing marker: String) throws -> pid_t {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(filePath: "/usr/bin/pgrep")
        process.arguments = ["-f", marker]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()

        let data = output.fileHandleForReading.readDataToEndOfFile()
        let values = String(decoding: data, as: UTF8.self)
            .split(whereSeparator: \.isNewline)
            .compactMap { pid_t($0) }
            .filter { $0 != getpid() }
        guard let pid = values.first else {
            throw SmokeFailure.coreProcessNotFound
        }
        return pid
    }
}

private enum SmokeFailure: Error {
    case corePathMissing
    case didNotConnect(String)
    case didNotDisconnect
    case preferencesUnavailable
    case runtimeListenerWasNotCreated(String)
    case proxyTestConfigurationUnavailable
    case proxyRequestFailed(Int32)
    case isolatedSystemProxyDidNotEnable(String)
    case runtimeSettingsDidNotRestart(String)
    case unchangedRuntimeSettingsRestarted
    case occupiedRuntimePortWasAccepted
    case runtimeSettingsRollbackFailed(String)
    case coreProcessNotFound
    case coreTerminationFailed(Int32)
    case crashRecoveryDidNotRestoreSystemProxy(String)
}

private final class OccupiedTCPPort {
    let descriptor: Int32
    let port: Int

    init() throws {
        let socketDescriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard socketDescriptor >= 0 else { throw SmokeFailure.coreTerminationFailed(errno) }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(
                    socketDescriptor,
                    $0,
                    socklen_t(MemoryLayout<sockaddr_in>.size)
                )
            }
        }
        guard bindResult == 0, Darwin.listen(socketDescriptor, 128) == 0 else {
            Darwin.close(socketDescriptor)
            throw SmokeFailure.coreTerminationFailed(errno)
        }

        var addressLength = socklen_t(MemoryLayout<sockaddr_in>.size)
        let lookupResult = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.getsockname(socketDescriptor, $0, &addressLength)
            }
        }
        guard lookupResult == 0 else {
            Darwin.close(socketDescriptor)
            throw SmokeFailure.coreTerminationFailed(errno)
        }
        descriptor = socketDescriptor
        port = Int(UInt16(bigEndian: address.sin_port))
    }

    deinit {
        Darwin.close(descriptor)
    }
}

private struct StaticSecretProvider: CoreSecretProviding {
    func loadOrCreate() throws -> String {
        "app-model-smoke-secret"
    }
}

private final class IsolatedSystemProxyBackend: SystemProxyBackend, @unchecked Sendable {
    private let lock = NSLock()
    private let service = SystemProxyNetworkService(id: "isolated", name: "Integration")
    private var currentState: SystemProxyServiceState
    private var storedApplyCount = 0

    init() throws {
        currentState = try SystemProxyServiceState(
            service: service,
            protocolExists: true,
            configuration: [
                SystemProxyKeys.httpEnable: .integer(0),
                SystemProxyKeys.httpsEnable: .integer(0),
                SystemProxyKeys.socksEnable: .integer(0)
            ]
        )
    }

    var applyCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return storedApplyCount
    }

    func enabledNetworkServices() throws -> [SystemProxyNetworkService] { [service] }

    func proxyStates(
        for services: [SystemProxyNetworkService]
    ) throws -> [SystemProxyServiceState] {
        lock.lock()
        defer { lock.unlock() }
        return try services.map { requested in
            guard requested == service else {
                throw SystemProxyError.serviceNotFound(requested.id)
            }
            return currentState
        }
    }

    func applyProxyStates(_ states: [SystemProxyServiceState]) throws {
        guard let state = states.first, states.count == 1 else {
            throw SystemProxyError.applyFailed
        }
        lock.lock()
        currentState = state
        storedApplyCount += 1
        lock.unlock()
    }
}
