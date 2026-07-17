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

actor AppleDNSProxyManager: DNSProxyManaging {
    private let providerBundleIdentifier: String
    private let manager: NEDNSProxyManager
    private let statusFile: DNSProxyStatusFile?

    init(
        providerBundleIdentifier: String = MClashNetworkExtensionIdentifiers.systemExtension,
        manager: NEDNSProxyManager = .shared(),
        statusFile: DNSProxyStatusFile? = nil
    ) {
        self.providerBundleIdentifier = providerBundleIdentifier
        self.manager = manager
        self.statusFile = statusFile ?? (try? DNSProxyStatusFile())
    }

    func configureAndEnable(_ configuration: NetworkExtensionRuntimeConfiguration) async throws {
        try await load()

        guard let statusFile else {
            throw NetworkExtensionControlFailure(
                operation: .configureDNSProxy,
                message: "The DNS Provider App Group runtime channel is unavailable"
            )
        }
        try statusFile.remove()

        let providerProtocol = NEDNSProxyProviderProtocol()
        providerProtocol.providerBundleIdentifier = providerBundleIdentifier
        providerProtocol.providerConfiguration = configuration.providerConfiguration
        manager.providerProtocol = providerProtocol
        manager.localizedDescription = "MClash DNS Proxy"
        manager.isEnabled = true

        try await save()
        try await load()
        guard manager.isEnabled,
              let savedProtocol = manager.providerProtocol,
              savedProtocol.providerBundleIdentifier == providerBundleIdentifier,
              Self.uint64(savedProtocol.providerConfiguration?["revision"])
                == configuration.revision,
              Self.uuid(savedProtocol.providerConfiguration?["activationIdentifier"])
                == configuration.activationIdentifier else {
            throw NetworkExtensionControlFailure(
                operation: .configureDNSProxy,
                message: "The saved DNS proxy ownership, revision, or activation identifier does not match the requested activation"
            )
        }
        try await waitForOperationalStatus(
            configuration: configuration,
            statusFile: statusFile
        )
    }

    func reload() async throws {
        try await load()
    }

    func runtimeStatus(
        for configuration: NetworkExtensionRuntimeConfiguration
    ) async throws -> DNSProxyRuntimeStatus {
        guard let statusFile else {
            throw NetworkExtensionControlFailure(
                operation: .configureDNSProxy,
                message: "The DNS Provider App Group runtime channel is unavailable"
            )
        }
        return try statusFile.readValidated(
            expectedRevision: configuration.revision,
            activationIdentifier: configuration.activationIdentifier
        )
    }

    func disable() async throws {
        try await load()
        guard let providerProtocol = manager.providerProtocol,
              providerProtocol.providerBundleIdentifier == providerBundleIdentifier
        else {
            // Never disable a DNS proxy configuration owned by another app.
            return
        }
        guard manager.isEnabled else {
            return
        }

        manager.isEnabled = false
        try await save()
        try await load()
        guard !manager.isEnabled else {
            throw NetworkExtensionControlFailure(
                operation: .disableDNSProxy,
                message: "DNS proxy remained enabled after shutdown was saved"
            )
        }
    }

    private func waitForOperationalStatus(
        configuration: NetworkExtensionRuntimeConfiguration,
        statusFile: DNSProxyStatusFile
    ) async throws {
        let deadline = ContinuousClock.now + .seconds(12)
        var lastError: Error = DNSProxyStatusFileError.documentMissing
        while ContinuousClock.now < deadline {
            do {
                let status = try statusFile.readValidated(
                    expectedRevision: configuration.revision,
                    activationIdentifier: configuration.activationIdentifier
                )
                if status.isOperational { return }
                if status.phase == .failed {
                    throw NetworkExtensionControlFailure(
                        operation: .configureDNSProxy,
                        message: "DNS Provider reported \(status.failureCategory?.rawValue ?? "unknown") during startup"
                    )
                }
                lastError = NetworkExtensionControlFailure(
                    operation: .configureDNSProxy,
                    message: "DNS Provider heartbeat is present but its Mihomo backend is not ready"
                )
            } catch {
                lastError = error
            }
            try await Task.sleep(for: .milliseconds(200))
        }
        throw NetworkExtensionControlFailure(
            operation: .configureDNSProxy,
            message: "DNS Provider did not publish a matching operational heartbeat within 12 seconds: \(lastError.localizedDescription)"
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

    private func load() async throws {
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

    private func save() async throws {
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
