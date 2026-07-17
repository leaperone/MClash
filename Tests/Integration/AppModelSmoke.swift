import Darwin
import Foundation

@main
struct AppModelSmoke {
    @MainActor
    static func main() async throws {
        let repository = URL(filePath: FileManager.default.currentDirectoryPath)
        let coreURL = repository.appending(
            path: "Sources/MClashApp/Resources/Core/\(CoreBinaryLocator.bundledResourceName)"
        )
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
                  model.localHTTPProxyPort == 17_890,
                  model.localSOCKSProxyPort == 17_890,
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
                  let startedAt = model.runningSession?.startedAt else {
                throw SmokeFailure.isolatedSystemProxyDidNotEnable(
                    "state=\(model.systemProxyState), "
                        + "applyCount=\(systemProxyBackend.applyCount), "
                        + "canChange=\(model.canPerform(.changeSystemProxy)), "
                        + "preparing=\(model.preparationInProgress), "
                        + "operations=\(model.operations), "
                        + "error=\(model.errorMessage ?? "none")"
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

            model.activeConfigURL = repository.appending(path: "Tests/Fixtures/no-listener.yaml")
            await model.connect()

            guard model.isConnected,
                  model.controllerIsReady,
                  let managedPort = model.runtimeConfig?.mixedPort,
                  managedPort > 0,
                  model.localHTTPProxyPort == managedPort,
                  model.localSOCKSProxyPort == managedPort,
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
    case didNotConnect(String)
    case didNotDisconnect
    case preferencesUnavailable
    case runtimeListenerWasNotCreated(String)
    case proxyTestConfigurationUnavailable
    case proxyRequestFailed(Int32)
    case isolatedSystemProxyDidNotEnable(String)
    case coreProcessNotFound
    case coreTerminationFailed(Int32)
    case crashRecoveryDidNotRestoreSystemProxy(String)
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
