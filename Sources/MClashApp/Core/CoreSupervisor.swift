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

    private final class ProcessControl: @unchecked Sendable {
        enum Interruption {
            case cancelled
            case timedOut
        }

        private let lock = NSLock()
        private var process: Process?
        private var interruption: Interruption?
        private var completed = false
        private var deadlineWorkItem: DispatchWorkItem?

        func install(_ process: Process) -> Bool {
            lock.withLock {
                guard interruption == nil, !completed else { return false }
                self.process = process
                return true
            }
        }

        var isInterrupted: Bool {
            lock.withLock { interruption != nil }
        }

        func cancel() {
            interrupt(.cancelled)
        }

        func scheduleTimeout(after interval: TimeInterval) {
            let workItem = DispatchWorkItem { [weak self] in
                self?.interrupt(.timedOut)
            }
            let shouldSchedule = lock.withLock {
                guard !completed, interruption == nil else { return false }
                deadlineWorkItem?.cancel()
                deadlineWorkItem = workItem
                return true
            }
            if shouldSchedule {
                DispatchQueue.global(qos: .utility).asyncAfter(
                    deadline: .now() + interval,
                    execute: workItem
                )
            }
        }

        private func interrupt(_ reason: Interruption) {
            let runningProcess = lock.withLock { () -> Process? in
                guard !completed else { return nil }
                if interruption == nil {
                    interruption = reason
                }
                return process
            }
            if runningProcess?.isRunning == true {
                runningProcess?.terminate()
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.25) {
                    guard let runningProcess, runningProcess.isRunning else { return }
                    Darwin.kill(runningProcess.processIdentifier, SIGKILL)
                }
            }
        }

        func claimCompletion() -> (claimed: Bool, interruption: Interruption?) {
            lock.withLock {
                guard !completed else { return (false, interruption) }
                completed = true
                process = nil
                deadlineWorkItem?.cancel()
                deadlineWorkItem = nil
                return (true, interruption)
            }
        }
    }

    private final class ProcessOutputCollector: @unchecked Sendable {
        private let lock = NSLock()
        private let maximumBytes: Int
        private var data = Data()
        private var truncated = false

        init(maximumBytes: Int) {
            self.maximumBytes = maximumBytes
        }

        func append(_ chunk: Data) {
            guard !chunk.isEmpty else { return }
            lock.withLock {
                let remaining = maximumBytes - data.count
                guard remaining > 0 else {
                    truncated = true
                    return
                }
                if chunk.count <= remaining {
                    data.append(chunk)
                } else {
                    data.append(chunk.prefix(remaining))
                    truncated = true
                }
            }
        }

        func renderedString() -> String {
            lock.withLock {
                let value = String(decoding: data, as: UTF8.self)
                if truncated {
                    return value + "\n[output truncated by MClash]"
                }
                return value
            }
        }
    }

    private let continuation: AsyncStream<CoreEvent>.Continuation
    private var managedProcess: ManagedProcess?
    private var currentState: CoreRunState = .stopped
    private var lastLaunchConfiguration: CoreLaunchConfiguration?
    private var expectedStopIDs = Set<UUID>()
    private var crashTimestamps: [Date] = []
    private var pendingRestartToken: UUID?
    private var validationInProgress = false
    private var validationProcessControl: ProcessControl?
    private var desiredRunGeneration = 0

    private let maximumCrashRestarts = 3
    private let crashWindow: TimeInterval = 10 * 60
    private let validationTimeout: TimeInterval
    private let maximumValidationOutputBytesPerStream: Int

    init(
        validationTimeout: TimeInterval = 15,
        maximumValidationOutputBytesPerStream: Int = 64 * 1_024
    ) {
        precondition(validationTimeout > 0)
        precondition(maximumValidationOutputBytesPerStream > 0)
        self.validationTimeout = validationTimeout
        self.maximumValidationOutputBytesPerStream = maximumValidationOutputBytesPerStream
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
        desiredRunGeneration &+= 1
        pendingRestartToken = nil
        validationProcessControl?.cancel()

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
            for _ in 0..<20 where managedProcess.process.isRunning {
                try? await Task.sleep(for: .milliseconds(50))
            }
        }

        if self.managedProcess?.id == managedProcess.id,
           !managedProcess.process.isRunning {
            self.managedProcess = nil
            expectedStopIDs.remove(managedProcess.id)
            cleanup(managedProcess)
            transition(to: .stopped)
        }
    }

    func validate(_ configuration: CoreLaunchConfiguration) async throws {
        try await acquireValidationSlot()
        defer { validationInProgress = false }

        transition(to: .validating)
        do {
            try await validateConfiguration(configuration)
            emitLog("Configuration validation succeeded.", stream: .supervisor)
            transition(to: .stopped)
        } catch is CancellationError {
            transition(to: .stopped)
            throw CancellationError()
        } catch {
            transition(to: .failed(error.localizedDescription))
            throw error
        }
    }

    /// Validates a profile without changing the state of a running core.
    /// Profile downloads use this path before the active session is stopped.
    func validateWithoutStateChanges(_ configuration: CoreLaunchConfiguration) async throws {
        try await acquireValidationSlot()
        defer { validationInProgress = false }

        try await validateConfiguration(configuration)
        emitLog("Configuration validation succeeded.", stream: .supervisor)
    }

    private func start(
        _ configuration: CoreLaunchConfiguration,
        validatesConfiguration: Bool
    ) async throws {
        guard managedProcess == nil else {
            throw CoreSupervisorError.alreadyRunning
        }

        desiredRunGeneration &+= 1
        let runGeneration = desiredRunGeneration
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

        try Task.checkCancellation()
        guard runGeneration == desiredRunGeneration else {
            throw CancellationError()
        }
        guard managedProcess == nil else {
            throw CoreSupervisorError.alreadyRunning
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
            guard runGeneration == desiredRunGeneration,
                  managedProcess?.id == managed.id,
                  process.isRunning else {
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
            let launchWasCancelled = error is CancellationError
                || runGeneration != desiredRunGeneration
            expectedStopIDs.insert(managed.id)
            process.terminate()
            if managedProcess?.id == managed.id {
                managedProcess = nil
                cleanup(managed)
            }
            expectedStopIDs.remove(managed.id)
            if launchWasCancelled {
                transition(to: .stopped)
                throw CancellationError()
            } else {
                transition(to: .failed(error.localizedDescription))
                throw error
            }
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

    private func validateConfiguration(_ configuration: CoreLaunchConfiguration) async throws {
        try preflight(configuration)
        try FileManager.default.createDirectory(
            at: configuration.homeDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )

        let result = try await runProcess(
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
            throw CoreSupervisorError.configurationInvalid(details)
        }
    }

    private func acquireValidationSlot() async throws {
        while validationInProgress {
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(50))
        }
        validationInProgress = true
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

    private func runProcess(
        executableURL: URL,
        arguments: [String],
        currentDirectoryURL: URL
    ) async throws -> ProcessResult {
        let control = ProcessControl()
        validationProcessControl = control
        defer {
            if validationProcessControl === control {
                validationProcessControl = nil
            }
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let process = Process()
                let standardOutput = Pipe()
                let standardError = Pipe()
                let outputCollector = ProcessOutputCollector(
                    maximumBytes: maximumValidationOutputBytesPerStream
                )
                let errorCollector = ProcessOutputCollector(
                    maximumBytes: maximumValidationOutputBytesPerStream
                )

                process.executableURL = executableURL
                process.arguments = arguments
                process.currentDirectoryURL = currentDirectoryURL
                process.standardOutput = standardOutput
                process.standardError = standardError

                standardOutput.fileHandleForReading.readabilityHandler = { handle in
                    outputCollector.append(handle.availableData)
                }
                standardError.fileHandleForReading.readabilityHandler = { handle in
                    errorCollector.append(handle.availableData)
                }

                process.terminationHandler = { process in
                    standardOutput.fileHandleForReading.readabilityHandler = nil
                    standardError.fileHandleForReading.readabilityHandler = nil
                    outputCollector.append(
                        standardOutput.fileHandleForReading.readDataToEndOfFile()
                    )
                    errorCollector.append(
                        standardError.fileHandleForReading.readDataToEndOfFile()
                    )
                    try? standardOutput.fileHandleForReading.close()
                    try? standardError.fileHandleForReading.close()

                    let completion = control.claimCompletion()
                    guard completion.claimed else { return }
                    switch completion.interruption {
                    case .cancelled:
                        continuation.resume(throwing: CancellationError())
                    case .timedOut:
                        continuation.resume(
                            throwing: CoreSupervisorError.configurationValidationTimedOut
                        )
                    case nil:
                        continuation.resume(
                            returning: ProcessResult(
                                status: process.terminationStatus,
                                standardOutput: outputCollector.renderedString(),
                                standardError: errorCollector.renderedString()
                            )
                        )
                    }
                }

                guard control.install(process) else {
                    standardOutput.fileHandleForReading.readabilityHandler = nil
                    standardError.fileHandleForReading.readabilityHandler = nil
                    let completion = control.claimCompletion()
                    if completion.claimed {
                        switch completion.interruption {
                        case .timedOut:
                            continuation.resume(
                                throwing: CoreSupervisorError.configurationValidationTimedOut
                            )
                        case .cancelled, nil:
                            continuation.resume(throwing: CancellationError())
                        }
                    }
                    return
                }

                do {
                    try process.run()
                    control.scheduleTimeout(after: validationTimeout)
                    if control.isInterrupted {
                        process.terminate()
                    }
                } catch {
                    standardOutput.fileHandleForReading.readabilityHandler = nil
                    standardError.fileHandleForReading.readabilityHandler = nil
                    process.terminationHandler = nil
                    let completion = control.claimCompletion()
                    if completion.claimed {
                        switch completion.interruption {
                        case .timedOut:
                            continuation.resume(
                                throwing: CoreSupervisorError.configurationValidationTimedOut
                            )
                        case .cancelled:
                            continuation.resume(throwing: CancellationError())
                        case nil:
                            continuation.resume(throwing: error)
                        }
                    }
                }
            }
        } onCancel: {
            control.cancel()
        }
    }
}
