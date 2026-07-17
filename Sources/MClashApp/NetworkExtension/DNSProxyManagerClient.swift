@preconcurrency import Foundation
@preconcurrency import NetworkExtension

protocol DNSProxyManaging: Sendable {
    func configureAndEnable(_ configuration: NetworkExtensionRuntimeConfiguration) async throws
    func reload() async throws
    func disable() async throws
}

actor AppleDNSProxyManager: DNSProxyManaging {
    private let providerBundleIdentifier: String
    private let manager: NEDNSProxyManager

    init(
        providerBundleIdentifier: String = MClashNetworkExtensionIdentifiers.systemExtension,
        manager: NEDNSProxyManager = .shared()
    ) {
        self.providerBundleIdentifier = providerBundleIdentifier
        self.manager = manager
    }

    func configureAndEnable(_ configuration: NetworkExtensionRuntimeConfiguration) async throws {
        try await load()

        let providerProtocol = NEDNSProxyProviderProtocol()
        providerProtocol.providerBundleIdentifier = providerBundleIdentifier
        providerProtocol.providerConfiguration = configuration.providerConfiguration
        manager.providerProtocol = providerProtocol
        manager.localizedDescription = "MClash DNS Proxy"
        manager.isEnabled = true

        try await save()
        try await load()
        guard manager.isEnabled else {
            throw NetworkExtensionControlFailure(
                operation: .configureDNSProxy,
                message: "DNS proxy was disabled by the system after saving"
            )
        }
    }

    func reload() async throws {
        try await load()
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
