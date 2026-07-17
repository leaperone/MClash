@preconcurrency import Foundation
import MClashNetworkShared
@preconcurrency import NetworkExtension

protocol TransparentProxyManaging: Sendable {
    func configure(_ configuration: NetworkExtensionRuntimeConfiguration) async throws
    func reload() async throws
    func start() async throws
    func stop() async throws
    func providerStatus() async throws -> TransparentProxyProviderStatus
    func quiesceProvider(revision: UInt64) async throws -> TransparentProxyProviderStatus
    func applyProviderConfiguration(
        _ configuration: NetworkExtensionRuntimeConfiguration
    ) async throws -> TransparentProxyProviderStatus
    func updateProviderConfiguration(
        _ configuration: NetworkExtensionRuntimeConfiguration
    ) async throws -> TransparentProxyProviderStatus
    func appRoutingActivity(after cursor: UInt64, limit: Int) async throws
        -> AppRoutingActivityBatch
    func clearAppRoutingActivity() async throws
}

private final class AppleTransparentProxyProviderMessageSession:
    TransparentProxyProviderMessageSession,
    @unchecked Sendable
{
    private let session: NETunnelProviderSession

    init(session: NETunnelProviderSession) {
        self.session = session
    }

    func sendProviderMessage(
        _ messageData: Data,
        responseHandler: @escaping @Sendable (Data?) -> Void
    ) throws {
        try session.sendProviderMessage(messageData) { responseData in
            responseHandler(responseData)
        }
    }
}

actor AppleTransparentProxyManager: TransparentProxyManaging {
    private struct LoadedManagers: @unchecked Sendable {
        let values: [NETransparentProxyManager]
    }

    private let providerBundleIdentifier: String
    private let connectionTimeout: Duration
    private var manager: NETransparentProxyManager?

    init(
        providerBundleIdentifier: String = MClashNetworkExtensionIdentifiers.systemExtension,
        connectionTimeout: Duration = .seconds(20)
    ) {
        self.providerBundleIdentifier = providerBundleIdentifier
        self.connectionTimeout = connectionTimeout
    }

    func configure(_ configuration: NetworkExtensionRuntimeConfiguration) async throws {
        let manager = try await loadOwnedManager() ?? NETransparentProxyManager()
        let providerProtocol = NETunnelProviderProtocol()
        providerProtocol.providerBundleIdentifier = providerBundleIdentifier
        providerProtocol.serverAddress = "MClash Local Transparent Proxy"
        providerProtocol.providerConfiguration = configuration.providerConfiguration

        manager.protocolConfiguration = providerProtocol
        manager.localizedDescription = MClashNetworkExtensionIdentifiers.localizedDescription
        manager.isEnabled = true

        try await save(manager)
        try await load(manager)
        self.manager = manager
    }

    func reload() async throws {
        let loadedManager: NETransparentProxyManager?
        if let manager {
            loadedManager = manager
        } else {
            loadedManager = try await loadOwnedManager()
        }
        guard let manager = loadedManager else {
            throw NetworkExtensionControlFailure(
                operation: .configureTransparentProxy,
                message: "No MClash transparent proxy configuration exists"
            )
        }
        try await load(manager)
        self.manager = manager
    }

    func start() async throws {
        try await reload()
        guard let manager, manager.isEnabled else {
            throw NetworkExtensionControlFailure(
                operation: .startTransparentProxy,
                message: "Transparent proxy configuration is disabled"
            )
        }

        do {
            try manager.connection.startVPNTunnel()
        } catch {
            throw NetworkExtensionControlFailure(
                operation: .startTransparentProxy,
                underlying: error
            )
        }
        try await waitForConnection(manager.connection, target: .connected)
    }

    func stop() async throws {
        let loadedManager: NETransparentProxyManager?
        if let manager {
            loadedManager = manager
        } else {
            loadedManager = try await loadOwnedManager()
        }
        guard let manager = loadedManager else {
            return
        }
        try await load(manager)
        self.manager = manager

        switch manager.connection.status {
        case .disconnected, .invalid:
            return
        default:
            manager.connection.stopVPNTunnel()
            try await waitForConnection(manager.connection, target: .disconnected)
        }
    }

    func providerStatus() async throws -> TransparentProxyProviderStatus {
        // Reloading makes this query useful after the host app has restarted:
        // the in-memory manager is not authoritative, while the configuration
        // persisted by NetworkExtension is.
        try await reload()
        return try await providerMessageClient().status()
    }

    func quiesceProvider(revision: UInt64) async throws -> TransparentProxyProviderStatus {
        try await providerMessageClient().quiesce(revision: revision)
    }

    func applyProviderConfiguration(
        _ configuration: NetworkExtensionRuntimeConfiguration
    ) async throws -> TransparentProxyProviderStatus {
        try await providerMessageClient().applyConfiguration(configuration)
    }

    func updateProviderConfiguration(
        _ configuration: NetworkExtensionRuntimeConfiguration
    ) async throws -> TransparentProxyProviderStatus {
        try await providerMessageClient().updateConfiguration(configuration)
    }

    func appRoutingActivity(
        after cursor: UInt64,
        limit: Int
    ) async throws -> AppRoutingActivityBatch {
        try await providerMessageClient().activities(after: cursor, limit: limit)
    }

    func clearAppRoutingActivity() async throws {
        try await providerMessageClient().clearActivity()
    }

    private func loadOwnedManager() async throws -> NETransparentProxyManager? {
        let loaded: LoadedManagers = try await withCheckedThrowingContinuation {
            continuation in
            NETransparentProxyManager.loadAllFromPreferences { managers, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: LoadedManagers(values: managers ?? []))
                }
            }
        }
        return loaded.values.first { manager in
            guard let providerProtocol = manager.protocolConfiguration
                as? NETunnelProviderProtocol
            else {
                return false
            }
            return providerProtocol.providerBundleIdentifier == providerBundleIdentifier
        }
    }

    private func providerMessageClient() throws -> TransparentProxyProviderMessageClient {
        guard let manager,
              let session = manager.connection as? NETunnelProviderSession
        else {
            throw TransparentProxyProviderMessageError.sessionUnavailable
        }
        return TransparentProxyProviderMessageClient(
            session: AppleTransparentProxyProviderMessageSession(session: session)
        )
    }

    private func save(_ manager: NETransparentProxyManager) async throws {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            manager.saveToPreferences { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            }
        }
    }

    private func load(_ manager: NETransparentProxyManager) async throws {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            manager.loadFromPreferences { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            }
        }
    }

    private func waitForConnection(
        _ connection: NEVPNConnection,
        target: NEVPNStatus
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: connectionTimeout)
        var observedConnectionAttempt = connection.status != .disconnected

        while clock.now < deadline {
            let status = connection.status
            if status == target {
                return
            }
            if target == .connected {
                switch status {
                case .connecting, .connected, .reasserting, .disconnecting:
                    observedConnectionAttempt = true
                case .invalid:
                    throw await connectionFailure(
                        connection,
                        operation: .startTransparentProxy,
                        fallback: "Transparent proxy connection became invalid"
                    )
                case .disconnected where observedConnectionAttempt:
                    throw await connectionFailure(
                        connection,
                        operation: .startTransparentProxy,
                        fallback: "Transparent proxy disconnected during startup"
                    )
                default:
                    break
                }
            }
            try await Task.sleep(for: .milliseconds(100))
        }

        throw await connectionFailure(
            connection,
            operation: target == .connected ? .startTransparentProxy : .stopTransparentProxy,
            fallback: "Timed out waiting for transparent proxy status \(target.rawValue)"
        )
    }

    private func connectionFailure(
        _ connection: NEVPNConnection,
        operation: NetworkExtensionControlOperation,
        fallback: String
    ) async -> NetworkExtensionControlFailure {
        let error = await lastDisconnectError(for: connection)
        guard let error else {
            return NetworkExtensionControlFailure(operation: operation, message: fallback)
        }

        let underlyingError = error as NSError
        var detail = underlyingError.localizedDescription
        if underlyingError.domain != NSCocoaErrorDomain {
            detail += " (\(underlyingError.domain) \(underlyingError.code))"
        }
        return NetworkExtensionControlFailure(
            operation: operation,
            message: "\(fallback): \(detail)"
        )
    }

    private func lastDisconnectError(for connection: NEVPNConnection) async -> Error? {
        await withCheckedContinuation { continuation in
            connection.fetchLastDisconnectError { error in
                continuation.resume(returning: error)
            }
        }
    }
}
