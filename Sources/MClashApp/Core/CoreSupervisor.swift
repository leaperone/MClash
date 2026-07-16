import Darwin
import Foundation

actor CoreSupervisor {
    nonisolated let events: AsyncStream<CoreEvent>

    private final class ManagedProcess: @unchecked Sendable {
        let id = UUID()
        let process: Process
        let standardOutput: Pipe
        let standardError: Pipe

        init(process: Process, standardOutput: Pipe, standardError: Pipe) {
            self.process = process
            self.standardOutput = standardOutput
            self.standardError = standardError
        }
    }

    private struct VersionPayload: Decodable {
        let version: String
    }

    private struct ProcessResult: Sendable {
        let status: Int32
        let standardOutput: String
        let standardError: String
    }

    private let continuation: AsyncStream<CoreEvent>.Continuation
    private var managedProcess: ManagedProcess?
    private var currentState: CoreRunState = .stopped
    private var lastLaunchConfiguration: CoreLaunchConfiguration?
    private var expectedStopIDs = Set<UUID>()
    private var crashTimestamps: [Date] = []
    private var pendingRestartToken: UUID?

    private let maximumCrashRestarts = 3
    private let crashWindow: TimeInterval = 10 * 60

    init() {
        let pair = AsyncStream<CoreEvent>.makeStream(
            of: CoreEvent.self,
            bufferingPolicy: .bufferingNewest(500)
        )
        events = pair.stream
        continuation = pair.continuation
    }

    deinit {
        continuation.finish()
    }

    func state() -> CoreRunState {
        currentState
    }

    func start(_ configuration: CoreLaunchConfiguration) async throws {
        try await start(configuration, validatesConfiguration: true)
    }

    func stop() async {
        pendingRestartToken = nil

        guard let managedProcess else {
            transition(to: .stopped)
            return
        }

        expectedStopIDs.insert(managedProcess.id)
        transition(to: .stopping)
        managedProcess.process.terminate()

        for _ in 0..<30 where managedProcess.process.isRunning {
            try? await Task.sleep(for: .milliseconds(100))
        }

        if managedProcess.process.isRunning {
            kill(managedProcess.process.processIdentifier, SIGKILL)
        }
    }

    func validate(_ configuration: CoreLaunchConfiguration) async throws {
        transition(to: .validating)
        try preflight(configuration)

        let result = try await Self.runProcess(
            executableURL: configuration.binaryURL,
            arguments: [
                "-t",
                "-d", configuration.homeDirectory.path,
                "-f", configuration.configURL.path
            ],
            currentDirectoryURL: configuration.homeDirectory
        )

        guard result.status == 0 else {
            let details = [result.standardError, result.standardOutput]
                .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                .joined(separator: "\n")
            transition(to: .failed(details))
            throw CoreSupervisorError.configurationInvalid(details)
        }

        emitLog("Configuration validation succeeded.", stream: .supervisor)
        transition(to: .stopped)
    }

    private func start(
        _ configuration: CoreLaunchConfiguration,
        validatesConfiguration: Bool
    ) async throws {
        guard managedProcess == nil else {
            throw CoreSupervisorError.alreadyRunning
        }

        pendingRestartToken = nil
        try preflight(configuration)
        try FileManager.default.createDirectory(
            at: configuration.homeDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )

        if validatesConfiguration {
            try await validate(configuration)
        }

        transition(to: .starting)

        let process = Process()
        let standardOutput = Pipe()
        let standardError = Pipe()
        let managed = ManagedProcess(
            process: process,
            standardOutput: standardOutput,
            standardError: standardError
        )

        process.executableURL = configuration.binaryURL
        process.currentDirectoryURL = configuration.homeDirectory
        process.arguments = [
            "-d", configuration.homeDirectory.path,
            "-f", configuration.configURL.path,
            "-ext-ctl", "127.0.0.1:\(configuration.controllerPort)",
            "-secret", configuration.secret
        ]
        process.standardOutput = standardOutput
        process.standardError = standardError

        standardOutput.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            Task { await self?.emitLog(text, stream: .standardOutput) }
        }

        standardError.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            Task { await self?.emitLog(text, stream: .standardError) }
        }

        process.terminationHandler = { [weak self] process in
            let status = process.terminationStatus
            Task { await self?.processTerminated(id: managed.id, status: status) }
        }

        managedProcess = managed
        lastLaunchConfiguration = configuration

        do {
            try process.run()
        } catch {
            managedProcess = nil
            cleanup(managed)
            let message = error.localizedDescription
            transition(to: .failed(message))
            throw CoreSupervisorError.launchFailed(message)
        }

        do {
            let version = try await waitUntilReady(configuration)
            guard managedProcess?.id == managed.id, process.isRunning else {
                throw CoreSupervisorError.launchFailed("The core exited during startup.")
            }
            transition(
                to: .running(
                    CoreSession(
                        endpoint: configuration.controllerEndpoint,
                        secret: configuration.secret,
                        version: version,
                        startedAt: Date()
                    )
                )
            )
        } catch {
            expectedStopIDs.insert(managed.id)
            process.terminate()
            if managedProcess?.id == managed.id {
                managedProcess = nil
                cleanup(managed)
            }
            transition(to: .failed(error.localizedDescription))
            throw error
        }
    }

    private func preflight(_ configuration: CoreLaunchConfiguration) throws {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: configuration.binaryURL.path) else {
            throw CoreSupervisorError.binaryNotFound(configuration.binaryURL.path)
        }
        guard fileManager.isExecutableFile(atPath: configuration.binaryURL.path) else {
            throw CoreSupervisorError.binaryNotExecutable(configuration.binaryURL.path)
        }
        guard fileManager.fileExists(atPath: configuration.configURL.path) else {
            throw CoreSupervisorError.configurationNotFound(configuration.configURL.path)
        }
    }

    private func waitUntilReady(_ configuration: CoreLaunchConfiguration) async throws -> String {
        let deadline = Date().addingTimeInterval(12)
        var lastError: Error?

        while Date() < deadline {
            guard managedProcess?.process.isRunning == true else {
                throw CoreSupervisorError.launchFailed("The core exited before becoming ready.")
            }

            do {
                var request = URLRequest(
                    url: configuration.controllerEndpoint.appending(path: "version")
                )
                request.timeoutInterval = 1
                request.setValue("Bearer \(configuration.secret)", forHTTPHeaderField: "Authorization")

                let (data, response) = try await URLSession.shared.data(for: request)
                if let httpResponse = response as? HTTPURLResponse,
                   (200..<300).contains(httpResponse.statusCode) {
                    return try JSONDecoder().decode(VersionPayload.self, from: data).version
                }
            } catch {
                lastError = error
            }

            try await Task.sleep(for: .milliseconds(200))
        }

        if let lastError {
            emitLog("Readiness check failed: \(lastError.localizedDescription)", stream: .supervisor)
        }
        throw CoreSupervisorError.readinessTimedOut
    }

    private func processTerminated(id: UUID, status: Int32) {
        guard let managedProcess, managedProcess.id == id else { return }
        let expected = expectedStopIDs.remove(id) != nil
        let configuration = lastLaunchConfiguration

        cleanup(managedProcess)
        self.managedProcess = nil

        if expected {
            transition(to: .stopped)
            return
        }

        let now = Date()
        crashTimestamps = crashTimestamps.filter { now.timeIntervalSince($0) < crashWindow }
        crashTimestamps.append(now)

        let message = "The proxy core exited unexpectedly with status \(status)."
        emitLog(message, stream: .supervisor)
        transition(to: .failed(message))

        guard crashTimestamps.count <= maximumCrashRestarts, let configuration else {
            emitLog("Automatic restart paused after repeated failures.", stream: .supervisor)
            return
        }

        let token = UUID()
        pendingRestartToken = token
        let delay = min(pow(2.0, Double(crashTimestamps.count - 1)), 8)

        Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            await self?.restartAfterCrash(configuration, token: token)
        }
    }

    private func restartAfterCrash(
        _ configuration: CoreLaunchConfiguration,
        token: UUID
    ) async {
        guard pendingRestartToken == token, managedProcess == nil else { return }
        emitLog("Restarting the proxy core after an unexpected exit.", stream: .supervisor)
        do {
            try await start(configuration, validatesConfiguration: false)
        } catch {
            emitLog("Automatic restart failed: \(error.localizedDescription)", stream: .supervisor)
        }
    }

    private func cleanup(_ managed: ManagedProcess) {
        managed.standardOutput.fileHandleForReading.readabilityHandler = nil
        managed.standardError.fileHandleForReading.readabilityHandler = nil
        try? managed.standardOutput.fileHandleForReading.close()
        try? managed.standardError.fileHandleForReading.close()
    }

    private func transition(to state: CoreRunState) {
        currentState = state
        continuation.yield(.stateChanged(state))
    }

    private func emitLog(_ text: String, stream: CoreLogLine.Stream) {
        for line in text.split(whereSeparator: \.isNewline) {
            continuation.yield(
                .log(CoreLogLine(stream: stream, message: String(line)))
            )
        }
    }

    private static func runProcess(
        executableURL: URL,
        arguments: [String],
        currentDirectoryURL: URL
    ) async throws -> ProcessResult {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            let standardOutput = Pipe()
            let standardError = Pipe()

            process.executableURL = executableURL
            process.arguments = arguments
            process.currentDirectoryURL = currentDirectoryURL
            process.standardOutput = standardOutput
            process.standardError = standardError
            process.terminationHandler = { process in
                let output = standardOutput.fileHandleForReading.readDataToEndOfFile()
                let error = standardError.fileHandleForReading.readDataToEndOfFile()
                continuation.resume(
                    returning: ProcessResult(
                        status: process.terminationStatus,
                        standardOutput: String(decoding: output, as: UTF8.self),
                        standardError: String(decoding: error, as: UTF8.self)
                    )
                )
            }

            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}
