import Foundation
import MClashNetworkShared

enum TransparentProxyProviderControlCommand: String, Codable, Sendable {
    case status
    case quiesce
    case applyConfiguration
    case activity
    case clearActivity
}

struct TransparentProxyProviderControlRequest: Codable, Equatable, Sendable {
    static let currentProtocolVersion = 1

    let protocolVersion: Int
    let command: TransparentProxyProviderControlCommand
    let revision: UInt64?
    let captureEnabled: Bool?
    let failOpen: Bool?
    let captureConfigurationSnapshot: Data?
    let mihomoSOCKSHost: String?
    let mihomoSOCKSPort: UInt16?
    let mihomoSOCKSUsername: String?
    let mihomoSOCKSPassword: String?
    let activityCursor: UInt64?
    let activityLimit: Int?

    init(
        command: TransparentProxyProviderControlCommand,
        revision: UInt64? = nil,
        captureEnabled: Bool? = nil,
        failOpen: Bool? = nil,
        captureConfigurationSnapshot: Data? = nil,
        mihomoSOCKSHost: String? = nil,
        mihomoSOCKSPort: UInt16? = nil,
        mihomoSOCKSUsername: String? = nil,
        mihomoSOCKSPassword: String? = nil,
        activityCursor: UInt64? = nil,
        activityLimit: Int? = nil
    ) {
        protocolVersion = Self.currentProtocolVersion
        self.command = command
        self.revision = revision
        self.captureEnabled = captureEnabled
        self.failOpen = failOpen
        self.captureConfigurationSnapshot = captureConfigurationSnapshot
        self.mihomoSOCKSHost = mihomoSOCKSHost
        self.mihomoSOCKSPort = mihomoSOCKSPort
        self.mihomoSOCKSUsername = mihomoSOCKSUsername
        self.mihomoSOCKSPassword = mihomoSOCKSPassword
        self.activityCursor = activityCursor
        self.activityLimit = activityLimit
    }
}

struct TransparentProxyProviderStatus: Codable, Equatable, Sendable {
    let protocolVersion: Int
    let provider: String
    let revision: UInt64
    let running: Bool
    let captureEnabled: Bool
    let failOpen: Bool
    let message: String?

    init(
        protocolVersion: Int = TransparentProxyProviderControlRequest.currentProtocolVersion,
        provider: String = "transparent-proxy",
        revision: UInt64,
        running: Bool,
        captureEnabled: Bool,
        failOpen: Bool,
        message: String? = nil
    ) {
        self.protocolVersion = protocolVersion
        self.provider = provider
        self.revision = revision
        self.running = running
        self.captureEnabled = captureEnabled
        self.failOpen = failOpen
        self.message = message
    }
}

private struct TransparentProxyProviderControlResponse: Decodable, Sendable {
    let protocolVersion: Int
    let accepted: Bool
    let provider: String
    let revision: UInt64
    let running: Bool
    let captureEnabled: Bool
    let failOpen: Bool
    let message: String?
    let activityBatch: AppRoutingActivityBatch?

    var status: TransparentProxyProviderStatus {
        TransparentProxyProviderStatus(
            protocolVersion: protocolVersion,
            provider: provider,
            revision: revision,
            running: running,
            captureEnabled: captureEnabled,
            failOpen: failOpen,
            message: message
        )
    }
}

enum TransparentProxyProviderMessageError: Error, Equatable, Sendable, LocalizedError {
    case sessionUnavailable
    case timedOut
    case missingResponse
    case missingActivityBatch
    case invalidResponse(String)
    case unsupportedProtocolVersion(expected: Int, actual: Int)
    case unexpectedProvider(String)
    case rejected(command: TransparentProxyProviderControlCommand, message: String?)
    case revisionDidNotAdvance(current: UInt64, proposed: UInt64)
    case revisionMismatch(expected: UInt64, actual: UInt64)
    case stateMismatch(
        expectedCaptureEnabled: Bool,
        actualCaptureEnabled: Bool,
        expectedFailOpen: Bool,
        actualFailOpen: Bool
    )

    var errorDescription: String? {
        switch self {
        case .sessionUnavailable:
            "The transparent proxy provider session is unavailable."
        case .timedOut:
            "The transparent proxy provider did not respond before the deadline."
        case .missingResponse:
            "The transparent proxy provider returned no response data."
        case .missingActivityBatch:
            "The transparent proxy provider returned no App Routing activity batch."
        case let .invalidResponse(message):
            "The transparent proxy provider returned an invalid response: \(message)"
        case let .unsupportedProtocolVersion(expected, actual):
            "Provider control protocol version mismatch (expected \(expected), received \(actual))."
        case let .unexpectedProvider(provider):
            "The response came from an unexpected provider: \(provider)."
        case let .rejected(command, message):
            "The provider rejected \(command.rawValue): \(message ?? "no reason supplied")"
        case let .revisionDidNotAdvance(current, proposed):
            "Provider configuration revision must advance beyond \(current); received \(proposed)."
        case let .revisionMismatch(expected, actual):
            "Provider revision mismatch (expected \(expected), received \(actual))."
        case let .stateMismatch(expectedCapture, actualCapture, expectedFailOpen, actualFailOpen):
            "Provider state mismatch (capture \(actualCapture)/\(expectedCapture), fail-open \(actualFailOpen)/\(expectedFailOpen))."
        }
    }
}

/// Callback-shaped on purpose: this matches `NETunnelProviderSession` and lets
/// the client enforce a deadline even if NetworkExtension never calls back.
protocol TransparentProxyProviderMessageSession: Sendable {
    func sendProviderMessage(
        _ messageData: Data,
        responseHandler: @escaping @Sendable (Data?) -> Void
    ) throws
}

struct TransparentProxyProviderMessageClient: Sendable {
    private let session: any TransparentProxyProviderMessageSession
    private let timeout: Duration

    init(
        session: any TransparentProxyProviderMessageSession,
        timeout: Duration = .seconds(5)
    ) {
        self.session = session
        self.timeout = timeout
    }

    func status(expectedRevision: UInt64? = nil) async throws -> TransparentProxyProviderStatus {
        try await send(
            TransparentProxyProviderControlRequest(command: .status),
            expectedRevision: expectedRevision
        )
    }

    func quiesce(revision: UInt64) async throws -> TransparentProxyProviderStatus {
        try await send(
            TransparentProxyProviderControlRequest(
                command: .quiesce,
                revision: revision,
                captureEnabled: false,
                failOpen: true
            ),
            expectedRevision: revision,
            expectedCaptureEnabled: false,
            expectedFailOpen: true
        )
    }

    func applyConfiguration(
        _ configuration: NetworkExtensionRuntimeConfiguration
    ) async throws -> TransparentProxyProviderStatus {
        let listener = configuration.mihomoListener
        return try await send(
            TransparentProxyProviderControlRequest(
                command: .applyConfiguration,
                revision: configuration.revision,
                captureEnabled: configuration.captureEnabled,
                failOpen: configuration.failOpen,
                captureConfigurationSnapshot: configuration.encodedCaptureSnapshot,
                mihomoSOCKSHost: listener?.ipv4Endpoint.host,
                mihomoSOCKSPort: listener?.port,
                mihomoSOCKSUsername: listener?.authentication?.username,
                mihomoSOCKSPassword: listener?.authentication?.password
            ),
            expectedRevision: configuration.revision,
            expectedCaptureEnabled: configuration.captureEnabled,
            expectedFailOpen: configuration.failOpen
        )
    }

    func activities(
        after cursor: UInt64,
        limit: Int = 200
    ) async throws -> AppRoutingActivityBatch {
        let response = try await validatedResponse(for: TransparentProxyProviderControlRequest(
            command: .activity,
            activityCursor: cursor,
            activityLimit: limit
        ))
        guard let batch = response.activityBatch else {
            throw TransparentProxyProviderMessageError.missingActivityBatch
        }
        return batch
    }

    func clearActivity() async throws {
        _ = try await validatedResponse(for: TransparentProxyProviderControlRequest(
            command: .clearActivity
        ))
    }

    /// Atomically changes the provider's decision inputs from the host's point
    /// of view. Any error after quiescing deliberately leaves capture disabled.
    @discardableResult
    func updateConfiguration(
        _ configuration: NetworkExtensionRuntimeConfiguration
    ) async throws -> TransparentProxyProviderStatus {
        let current = try await status()
        guard configuration.revision > current.revision else {
            throw TransparentProxyProviderMessageError.revisionDidNotAdvance(
                current: current.revision,
                proposed: configuration.revision
            )
        }
        _ = try await quiesce(revision: configuration.revision)
        _ = try await applyConfiguration(configuration)
        return try await status(expectedRevision: configuration.revision)
    }

    private func send(
        _ request: TransparentProxyProviderControlRequest,
        expectedRevision: UInt64? = nil,
        expectedCaptureEnabled: Bool? = nil,
        expectedFailOpen: Bool? = nil
    ) async throws -> TransparentProxyProviderStatus {
        let response = try await validatedResponse(for: request)
        if let expectedRevision, response.revision != expectedRevision {
            throw TransparentProxyProviderMessageError.revisionMismatch(
                expected: expectedRevision,
                actual: response.revision
            )
        }
        if let expectedCaptureEnabled,
           let expectedFailOpen,
           (response.captureEnabled != expectedCaptureEnabled || response.failOpen != expectedFailOpen) {
            throw TransparentProxyProviderMessageError.stateMismatch(
                expectedCaptureEnabled: expectedCaptureEnabled,
                actualCaptureEnabled: response.captureEnabled,
                expectedFailOpen: expectedFailOpen,
                actualFailOpen: response.failOpen
            )
        }
        return response.status
    }

    private func validatedResponse(
        for request: TransparentProxyProviderControlRequest
    ) async throws -> TransparentProxyProviderControlResponse {
        let messageData = try JSONEncoder().encode(request)
        let responseData = try await exchange(messageData)
        let response: TransparentProxyProviderControlResponse
        do {
            response = try JSONDecoder().decode(
                TransparentProxyProviderControlResponse.self,
                from: responseData
            )
        } catch {
            throw TransparentProxyProviderMessageError.invalidResponse(
                String(describing: error)
            )
        }

        guard response.protocolVersion == TransparentProxyProviderControlRequest.currentProtocolVersion else {
            throw TransparentProxyProviderMessageError.unsupportedProtocolVersion(
                expected: TransparentProxyProviderControlRequest.currentProtocolVersion,
                actual: response.protocolVersion
            )
        }
        guard response.provider == "transparent-proxy" else {
            throw TransparentProxyProviderMessageError.unexpectedProvider(response.provider)
        }
        guard response.accepted else {
            throw TransparentProxyProviderMessageError.rejected(
                command: request.command,
                message: response.message
            )
        }
        return response
    }

    private func exchange(_ messageData: Data) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            let gate = ProviderMessageContinuationGate(continuation: continuation)
            let timeoutTask = Task.detached { [timeout] in
                do {
                    try await Task.sleep(for: timeout)
                    gate.resume(throwing: TransparentProxyProviderMessageError.timedOut)
                } catch {
                    // Cancellation means the response path already completed.
                }
            }
            gate.installTimeoutTask(timeoutTask)
            do {
                try session.sendProviderMessage(messageData) { responseData in
                    guard let responseData else {
                        gate.resume(throwing: TransparentProxyProviderMessageError.missingResponse)
                        return
                    }
                    gate.resume(returning: responseData)
                }
            } catch {
                gate.resume(throwing: error)
            }
        }
    }
}

private final class ProviderMessageContinuationGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Data, Error>?
    private var timeoutTask: Task<Void, Never>?

    init(continuation: CheckedContinuation<Data, Error>) {
        self.continuation = continuation
    }

    func resume(returning data: Data) {
        resolve(.success(data))
    }

    func resume(throwing error: any Error) {
        resolve(.failure(error))
    }

    func installTimeoutTask(_ task: Task<Void, Never>) {
        lock.lock()
        guard continuation != nil else {
            lock.unlock()
            task.cancel()
            return
        }
        timeoutTask = task
        lock.unlock()
    }

    private func resolve(_ result: Result<Data, any Error>) {
        lock.lock()
        guard let continuation else {
            lock.unlock()
            return
        }
        self.continuation = nil
        let timeoutTask = self.timeoutTask
        self.timeoutTask = nil
        lock.unlock()
        timeoutTask?.cancel()
        continuation.resume(with: result)
    }
}
