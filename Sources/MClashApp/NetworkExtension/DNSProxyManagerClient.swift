@preconcurrency import Foundation
import MClashNetworkShared
@preconcurrency import NetworkExtension

protocol DNSProxyManaging: Sendable {
    func configureAndEnable(_ configuration: NetworkExtensionRuntimeConfiguration) async throws
    func reload() async throws
    func runtimeStatus(
        for configuration: NetworkExtensionRuntimeConfiguration
    ) async throws -> DNSProxyRuntimeStatus
    func disable() async throws
}

/// A value snapshot keeps the persistence transaction testable without making
/// `AppleDNSProxyManager` depend directly on NetworkExtension's process-wide
/// singleton. All values placed in `providerConfiguration` are property-list
/// Foundation objects, but Foundation does not declare that dictionary
/// `Sendable`, so access remains serialized by `AppleDNSProxyManager`.
struct DNSProxyPreferenceSnapshot: @unchecked Sendable {
    var providerBundleIdentifier: String?
    var providerConfiguration: [String: Any]?
    var localizedDescription: String?
    var isEnabled: Bool
}

protocol DNSProxyPreferenceManaging: Sendable {
    func load() async throws -> DNSProxyPreferenceSnapshot
    func save(_ snapshot: DNSProxyPreferenceSnapshot) async throws
}

private final class AppleDNSProxyPreferences: DNSProxyPreferenceManaging, @unchecked Sendable {
    private let manager: NEDNSProxyManager

    init(manager: NEDNSProxyManager = .shared()) {
        self.manager = manager
    }

    func load() async throws -> DNSProxyPreferenceSnapshot {
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
        return DNSProxyPreferenceSnapshot(
            providerBundleIdentifier: manager.providerProtocol?.providerBundleIdentifier,
            providerConfiguration: manager.providerProtocol?.providerConfiguration,
            localizedDescription: manager.localizedDescription,
            isEnabled: manager.isEnabled
        )
    }

    func save(_ snapshot: DNSProxyPreferenceSnapshot) async throws {
        if snapshot.providerBundleIdentifier != nil || snapshot.providerConfiguration != nil {
            let providerProtocol = NEDNSProxyProviderProtocol()
            providerProtocol.providerBundleIdentifier = snapshot.providerBundleIdentifier
            providerProtocol.providerConfiguration = snapshot.providerConfiguration
            manager.providerProtocol = providerProtocol
        } else {
            manager.providerProtocol = nil
        }
        manager.localizedDescription = snapshot.localizedDescription
        manager.isEnabled = snapshot.isEnabled

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
}

actor AppleDNSProxyManager: DNSProxyManaging {
    private static let localizedDescription = "MClash DNS Proxy"

    private let providerBundleIdentifier: String
    private let preferences: any DNSProxyPreferenceManaging
    private let statusFile: DNSProxyStatusFile?
    private let statusFileInitializationError: Error?
    private let operationalStatusTimeout: Duration
    private let operationalStatusPollInterval: Duration

    init(
        providerBundleIdentifier: String = MClashNetworkExtensionIdentifiers.systemExtension,
        manager: NEDNSProxyManager = .shared(),
        statusFile: DNSProxyStatusFile? = nil
    ) {
        self.providerBundleIdentifier = providerBundleIdentifier
        preferences = AppleDNSProxyPreferences(manager: manager)
        if let statusFile {
            self.statusFile = statusFile
            statusFileInitializationError = nil
        } else {
            do {
                self.statusFile = try DNSProxyStatusFile()
                statusFileInitializationError = nil
            } catch {
                self.statusFile = nil
                statusFileInitializationError = error
            }
        }
        operationalStatusTimeout = .seconds(12)
        operationalStatusPollInterval = .milliseconds(200)
    }

    init(
        providerBundleIdentifier: String = MClashNetworkExtensionIdentifiers.systemExtension,
        preferences: any DNSProxyPreferenceManaging,
        statusFile: DNSProxyStatusFile?,
        operationalStatusTimeout: Duration = .seconds(12),
        operationalStatusPollInterval: Duration = .milliseconds(200)
    ) {
        self.providerBundleIdentifier = providerBundleIdentifier
        self.preferences = preferences
        self.statusFile = statusFile
        statusFileInitializationError = nil
        self.operationalStatusTimeout = operationalStatusTimeout
        self.operationalStatusPollInterval = operationalStatusPollInterval
    }

    func configureAndEnable(_ configuration: NetworkExtensionRuntimeConfiguration) async throws {
        _ = try await load(operation: .configureDNSProxy)

        guard let statusFile else {
            throw NetworkExtensionControlFailure(
                operation: .configureDNSProxy,
                message: unavailableStatusChannelMessage
            )
        }
        // Remove the previous activation's heartbeat before enabling. Removing
        // it after save can race with the newly launched provider and erase the
        // only proof that NetworkExtension actually started it.
        do {
            try statusFile.remove()
        } catch {
            throw NetworkExtensionControlFailure(
                operation: .configureDNSProxy,
                message: "Could not clear the previous DNS Provider heartbeat: "
                    + error.localizedDescription
            )
        }

        let desired = DNSProxyPreferenceSnapshot(
            providerBundleIdentifier: providerBundleIdentifier,
            providerConfiguration: configuration.providerConfiguration,
            localizedDescription: Self.localizedDescription,
            isEnabled: true
        )
        try await save(desired, operation: .configureDNSProxy)

        // `saveToPreferences` completing only confirms that the request was
        // accepted. Reload the system-owned copy and verify all activation
        // identity fields before waiting for provider data-plane evidence.
        let persisted = try await load(operation: .configureDNSProxy)
        try validateEnabledPreferences(
            persisted,
            for: configuration,
            operation: .configureDNSProxy
        )

        try await waitForOperationalStatus(
            configuration: configuration,
            statusFile: statusFile
        )
    }

    func reload() async throws {
        _ = try await load(operation: .inspectDNSProxy)
    }

    func runtimeStatus(
        for configuration: NetworkExtensionRuntimeConfiguration
    ) async throws -> DNSProxyRuntimeStatus {
        // A heartbeat file may outlive a disabled or replaced preference. The
        // persisted NEDNSProxyManager state is therefore part of every health
        // read, not just the initial enable transaction.
        let persisted = try await load(operation: .inspectDNSProxy)
        try validateEnabledPreferences(
            persisted,
            for: configuration,
            operation: .inspectDNSProxy
        )

        guard let statusFile else {
            throw NetworkExtensionControlFailure(
                operation: .inspectDNSProxy,
                message: unavailableStatusChannelMessage
            )
        }
        do {
            return try statusFile.readValidated(
                expectedRevision: configuration.revision,
                activationIdentifier: configuration.activationIdentifier
            )
        } catch {
            throw NetworkExtensionControlFailure(
                operation: .inspectDNSProxy,
                message: "The persisted DNS proxy is enabled, but its runtime heartbeat is invalid: "
                    + error.localizedDescription
            )
        }
    }

    func disable() async throws {
        let persisted = try await load(operation: .disableDNSProxy)
        guard persisted.providerBundleIdentifier == providerBundleIdentifier else {
            // Never disable a DNS proxy configuration owned by another app.
            return
        }
        guard persisted.isEnabled else {
            return
        }

        var disabled = persisted
        disabled.isEnabled = false
        try await save(disabled, operation: .disableDNSProxy)
        let readback = try await load(operation: .disableDNSProxy)
        guard readback.providerBundleIdentifier == providerBundleIdentifier else {
            throw NetworkExtensionControlFailure(
                operation: .disableDNSProxy,
                message: "The MClash DNS proxy configuration changed ownership during shutdown"
            )
        }
        guard !readback.isEnabled else {
            throw NetworkExtensionControlFailure(
                operation: .disableDNSProxy,
                message: "DNS proxy remained enabled after shutdown was saved"
            )
        }
    }

    private func validateEnabledPreferences(
        _ persisted: DNSProxyPreferenceSnapshot,
        for configuration: NetworkExtensionRuntimeConfiguration,
        operation: NetworkExtensionControlOperation
    ) throws {
        guard persisted.isEnabled else {
            throw NetworkExtensionControlFailure(
                operation: operation,
                message: "The persisted MClash DNS proxy configuration is disabled"
            )
        }
        guard persisted.providerBundleIdentifier == providerBundleIdentifier else {
            throw NetworkExtensionControlFailure(
                operation: operation,
                message: "The persisted DNS proxy configuration is not owned by the MClash Network Extension"
            )
        }
        guard Self.uint64(persisted.providerConfiguration?["revision"])
                == configuration.revision,
              Self.uuid(persisted.providerConfiguration?["activationIdentifier"])
                == configuration.activationIdentifier
        else {
            throw NetworkExtensionControlFailure(
                operation: operation,
                message: "The saved DNS proxy revision or activation identifier does not match the requested activation"
            )
        }
    }

    private func waitForOperationalStatus(
        configuration: NetworkExtensionRuntimeConfiguration,
        statusFile: DNSProxyStatusFile
    ) async throws {
        let deadline = ContinuousClock.now + operationalStatusTimeout
        var lastError: Error = DNSProxyStatusFileError.documentMissing
        while ContinuousClock.now < deadline {
            let status: DNSProxyRuntimeStatus
            do {
                status = try statusFile.readValidated(
                    expectedRevision: configuration.revision,
                    activationIdentifier: configuration.activationIdentifier
                )
            } catch {
                lastError = error
                try await Task.sleep(for: operationalStatusPollInterval)
                continue
            }
            if status.isOperational { return }
            if status.phase == .failed {
                throw NetworkExtensionControlFailure(
                    operation: .configureDNSProxy,
                    message: "DNS Provider reported "
                        + "\(status.failureCategory?.rawValue ?? "unknown") during startup"
                )
            }
            lastError = NetworkExtensionControlFailure(
                operation: .configureDNSProxy,
                message: "DNS Provider heartbeat is present but its Mihomo backend is not ready"
            )
            try await Task.sleep(for: operationalStatusPollInterval)
        }
        throw NetworkExtensionControlFailure(
            operation: .configureDNSProxy,
            message: "DNS Provider did not publish a matching operational heartbeat within "
                + "\(operationalStatusTimeout): \(lastError.localizedDescription)"
        )
    }

    private static func uint64(_ value: Any?) -> UInt64? {
        switch value {
        case let value as UInt64: value
        case let value as Int where value >= 0: UInt64(value)
        case let value as NSNumber where value.int64Value >= 0: value.uint64Value
        case let value as String: UInt64(value)
        default: nil
        }
    }

    private static func uuid(_ value: Any?) -> UUID? {
        switch value {
        case let value as UUID: value
        case let value as String: UUID(uuidString: value)
        default: nil
        }
    }

    private func load(
        operation: NetworkExtensionControlOperation
    ) async throws -> DNSProxyPreferenceSnapshot {
        do {
            return try await preferences.load()
        } catch {
            throw preferenceFailure(
                operation: operation,
                stage: "load",
                error: error
            )
        }
    }

    private func save(
        _ snapshot: DNSProxyPreferenceSnapshot,
        operation: NetworkExtensionControlOperation
    ) async throws {
        do {
            try await preferences.save(snapshot)
        } catch {
            throw preferenceFailure(
                operation: operation,
                stage: "save",
                error: error
            )
        }
    }

    private func preferenceFailure(
        operation: NetworkExtensionControlOperation,
        stage: String,
        error: Error
    ) -> NetworkExtensionControlFailure {
        let underlying = NetworkExtensionControlFailure(operation: operation, underlying: error)
        return NetworkExtensionControlFailure(
            operation: operation,
            message: "Could not \(stage) NEDNSProxyManager preferences: \(underlying.message)"
        )
    }

    private var unavailableStatusChannelMessage: String {
        let prefix = "The DNS Provider App Group runtime channel is unavailable"
        guard let statusFileInitializationError else { return prefix }
        return prefix + ": " + statusFileInitializationError.localizedDescription
    }
}
