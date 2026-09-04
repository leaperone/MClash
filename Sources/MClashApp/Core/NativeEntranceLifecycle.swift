import Foundation

/// The capture capabilities owned by MClash's native runtime.
///
/// System Proxy and App Routing are deliberately represented as entrances,
/// rather than policy rules or Mihomo settings.  This value is also the
/// boundary used by the host app and the Network Extension, so a native/test
/// instance can exercise activation without a controller endpoint or YAML.
enum NativeEntranceCapability: String, CaseIterable, Hashable, Sendable {
    case systemProxy
    case appRouting
}

struct NativeEntranceActivation: Equatable, Sendable {
    let revision: UInt64
    let enabled: Set<NativeEntranceCapability>
    let generation: UInt64

    var systemProxyEnabled: Bool { enabled.contains(.systemProxy) }
    var appRoutingEnabled: Bool { enabled.contains(.appRouting) }
}

enum NativeEntranceApplyOutcome: Equatable, Sendable {
    case running
    case requiresReboot
}

struct NativeEntranceActivationResult: Equatable, Sendable {
    let activation: NativeEntranceActivation
    let outcome: NativeEntranceApplyOutcome
}

/// MClash-owned inputs for the host System Proxy side effect. The snapshot
/// URL is deliberately part of the transaction so a replacement can restore
/// the exact pre-activation state after a later stage fails.
struct NativeSystemProxyConfiguration: Sendable {
    let endpoints: LocalSystemProxyEndpoints
    let bypassDomains: [String]?
    let snapshotURL: URL
}

/// Complete native entrance transaction passed to the side-effect boundary.
/// It is intentionally not Equatable or printable: the embedded runtime
/// configuration may contain connector credentials. Rollback data is opaque
/// and never included in diagnostics.
struct NativeEntranceTransaction: Sendable {
    let activation: NativeEntranceActivation
    let runtimeConfiguration: NetworkExtensionRuntimeConfiguration?
    let systemProxyEndpoints: LocalSystemProxyEndpoints?
    let systemProxySnapshot: SystemProxySnapshot?
    let rollbackToken: Data?
    let systemProxyConfiguration: NativeSystemProxyConfiguration?

    init(
        activation: NativeEntranceActivation,
        runtimeConfiguration: NetworkExtensionRuntimeConfiguration? = nil,
        systemProxyEndpoints: LocalSystemProxyEndpoints? = nil,
        systemProxySnapshot: SystemProxySnapshot? = nil,
        rollbackToken: Data? = nil,
        systemProxyConfiguration: NativeSystemProxyConfiguration? = nil,
        systemProxyBypassDomains: [String]? = nil,
        systemProxySnapshotURL: URL? = nil
    ) {
        self.activation = activation
        self.runtimeConfiguration = runtimeConfiguration
        self.systemProxyEndpoints = systemProxyEndpoints
        self.systemProxySnapshot = systemProxySnapshot
        self.rollbackToken = rollbackToken
        self.systemProxyConfiguration = systemProxyConfiguration ?? {
            guard let endpoints = systemProxyEndpoints,
                  let snapshotURL = systemProxySnapshotURL else { return nil }
            return NativeSystemProxyConfiguration(
                endpoints: endpoints,
                bypassDomains: systemProxyBypassDomains,
                snapshotURL: snapshotURL
            )
        }()
    }
}

/// Injectable boundary for SystemConfiguration/System Proxy side effects.
/// Production wiring may implement this with SystemProxyManager; tests use a
/// recording fake. No native entrance backend calls privileged APIs directly.
protocol NativeSystemProxySideEffectBoundary: Sendable {
    func activate(_ configuration: NativeSystemProxyConfiguration) async throws
    func restore(snapshotAt url: URL) async throws
    func deactivate(snapshotAt url: URL?) async throws
}

enum NativeEntranceLifecycleState: Equatable, Sendable {
    case inactive
    case activating(NativeEntranceActivation)
    case active(NativeEntranceActivation)
    case requiresReboot(NativeEntranceActivation)
    case deactivating(NativeEntranceActivation)
    case failed(String)

    var activation: NativeEntranceActivation? {
        switch self {
        case let .activating(value), let .active(value),
             let .requiresReboot(value), let .deactivating(value):
            return value
        case .inactive, .failed:
            return nil
        }
    }
}

enum NativeEntranceLifecycleError: Error, Equatable, LocalizedError, Sendable {
    case invalidRevision
    case noEnabledEntrance
    case mutuallyExclusiveEntrances
    case staleRevision(current: UInt64, requested: UInt64)

    var errorDescription: String? {
        switch self {
        case .invalidRevision:
            "Native entrance activation requires a non-zero revision."
        case .noEnabledEntrance:
            "Native entrance activation requires at least one enabled entrance."
        case .mutuallyExclusiveEntrances:
            "macOS System Proxy and App Routing cannot capture traffic at the same time."
        case let .staleRevision(current, requested):
            "Native entrance revision \(requested) is older than the active revision \(current)."
        }
    }
}

/// Side-effect boundary for capture providers. Implementations may be backed
/// by NetworkExtension/SystemConfiguration, while tests use an in-memory
/// backend. No implementation is allowed to invoke a Mihomo controller.
protocol NativeEntranceLifecycleBackend: Sendable {
    /// Atomically applies `transaction`. When replacing a committed value,
    /// `previous` is the exact rollback input the backend must restore before
    /// returning an error from a partially applied change.
    func apply(
        _ transaction: NativeEntranceTransaction,
        replacing previous: NativeEntranceTransaction?
    ) async throws -> NativeEntranceApplyOutcome
    func deactivate(_ transaction: NativeEntranceTransaction) async throws
}

/// Production adapter for the Network Extension and System Proxy side-effect
/// boundaries. Exactly one capture entrance is active at a time, and a failed
/// transition restores the previously committed entrance before returning.
final class NativeNetworkExtensionEntranceBackend: NativeEntranceLifecycleBackend, @unchecked Sendable {
    private let control: any NetworkExtensionControlling
    private let lock = NSLock()
    private var progressHandler: (@Sendable (NetworkExtensionEnableProgress) -> Void)?
    private let systemProxy: (any NativeSystemProxySideEffectBoundary)?

    init(
        control: any NetworkExtensionControlling,
        systemProxy: (any NativeSystemProxySideEffectBoundary)? = nil
    ) {
        self.control = control
        self.systemProxy = systemProxy
    }

    func setProgressHandler(
        _ handler: (@Sendable (NetworkExtensionEnableProgress) -> Void)?
    ) {
        lock.lock()
        progressHandler = handler
        lock.unlock()
    }

    private func reportProgress(_ progress: NetworkExtensionEnableProgress) {
        lock.lock()
        let handler = progressHandler
        lock.unlock()
        handler?(progress)
    }

    func apply(
        _ transaction: NativeEntranceTransaction,
        replacing previous: NativeEntranceTransaction?
    ) async throws -> NativeEntranceApplyOutcome {
        if transaction.activation.systemProxyEnabled {
            guard let systemProxy, let configuration = transaction.systemProxyConfiguration else {
                throw NativeEntranceBackendError.missingSystemProxyConfiguration
            }
            if previous?.activation.appRoutingEnabled == true {
                try await control.disable()
            } else if previous?.activation.systemProxyEnabled == true,
                      let previousURL = previous?.systemProxyConfiguration?.snapshotURL {
                try await systemProxy.deactivate(snapshotAt: previousURL)
            }
            do {
                try await systemProxy.activate(configuration)
                return .running
            } catch {
                do {
                    if let previousConfiguration = previous?.runtimeConfiguration,
                       previous?.activation.appRoutingEnabled == true {
                        _ = try await control.enable(previousConfiguration) { _ in }
                    } else if let previousSystemProxy = previous?.systemProxyConfiguration,
                              previous?.activation.systemProxyEnabled == true {
                        try await systemProxy.activate(previousSystemProxy)
                    }
                } catch {
                    throw NativeEntranceBackendError.rollbackFailed
                }
                throw error
            }
        }
        guard let configuration = transaction.runtimeConfiguration else {
            throw NativeEntranceBackendError.missingRuntimeConfiguration
        }
        if previous?.activation.systemProxyEnabled == true {
            guard let systemProxy,
                  let previousSystemProxy = previous?.systemProxyConfiguration else {
                throw NativeEntranceBackendError.missingSystemProxyConfiguration
            }
            try await systemProxy.deactivate(snapshotAt: previousSystemProxy.snapshotURL)
            do {
                let outcome = try await control.enable(configuration) { [weak self] progress in
                    self?.reportProgress(progress)
                }
                return switch outcome {
                case .running: .running
                case .requiresReboot: .requiresReboot
                }
            } catch {
                do {
                    try await systemProxy.activate(previousSystemProxy)
                } catch {
                    throw NativeEntranceBackendError.rollbackFailed
                }
                throw error
            }
        }
        if let previousConfiguration = previous?.runtimeConfiguration {
            do {
                let outcome = try await control.updateRuntimeConfiguration(configuration)
                return switch outcome {
                case .running: .running
                case .requiresReboot: .requiresReboot
                }
            } catch {
                do {
                    _ = try await control.updateRuntimeConfiguration(previousConfiguration)
                } catch {
                    throw NativeEntranceBackendError.rollbackFailed
                }
                throw error
            }
        }
        let outcome = try await control.enable(configuration) { [weak self] progress in
            self?.reportProgress(progress)
        }
        return switch outcome {
        case .running: .running
        case .requiresReboot: .requiresReboot
        }
    }

    func deactivate(_ transaction: NativeEntranceTransaction) async throws {
        if transaction.activation.systemProxyEnabled {
            guard let systemProxy else { throw NativeEntranceBackendError.missingSystemProxyConfiguration }
            try await systemProxy.deactivate(
                snapshotAt: transaction.systemProxyConfiguration?.snapshotURL
            )
        } else {
            try await control.disable()
        }
    }
}

enum NativeEntranceBackendError: Error, Equatable, LocalizedError, Sendable {
    case missingRuntimeConfiguration
    case missingSystemProxyConfiguration
    case systemProxyVerificationFailed
    case rollbackFailed

    var errorDescription: String? {
        switch self {
        case .missingRuntimeConfiguration:
            "Native App Routing activation is missing its runtime configuration."
        case .missingSystemProxyConfiguration:
            "Native System Proxy activation is missing its side-effect configuration."
        case .systemProxyVerificationFailed:
            "Native System Proxy activation could not be verified."
        case .rollbackFailed:
            "Native entrance update failed and the previous entrance could not be restored."
        }
    }
}

extension SystemProxyManager: NativeSystemProxySideEffectBoundary {
    func activate(_ configuration: NativeSystemProxyConfiguration) async throws {
        do {
            _ = try activate(
                endpoints: configuration.endpoints,
                bypassDomains: configuration.bypassDomains,
                savingSnapshotTo: configuration.snapshotURL
            )
            guard try configurationMatches(
                endpoints: configuration.endpoints,
                bypassDomains: configuration.bypassDomains
            ) else {
                throw NativeEntranceBackendError.systemProxyVerificationFailed
            }
        } catch {
            let activationError = error
            if FileManager.default.fileExists(atPath: configuration.snapshotURL.path) {
                do {
                    try restoreSnapshotAndRemove(from: configuration.snapshotURL)
                } catch {
                    throw NativeEntranceBackendError.rollbackFailed
                }
            }
            throw activationError
        }
    }

    func restore(snapshotAt url: URL) async throws {
        try restoreSnapshotAndRemove(from: url)
    }

    func deactivate(snapshotAt url: URL?) async throws {
        guard let url else {
            throw NativeEntranceBackendError.missingSystemProxyConfiguration
        }
        try restoreSnapshotAndRemove(from: url)
    }
}

/// Transactional lifecycle owner for native capture entrances.
///
/// The coordinator serializes activation/deactivation and keeps the last
/// committed activation until the replacement has succeeded. This prevents a
/// failed App Routing/System Proxy transition from silently leaving a half
/// applied state, while keeping production's legacy AppModel path unchanged
/// until the native runtime is promoted.
actor NativeEntranceLifecycleCoordinator {
    private let backend: any NativeEntranceLifecycleBackend
    private(set) var state: NativeEntranceLifecycleState = .inactive
    private var generation: UInt64 = 0
    /// The last activation acknowledged by the backend.  A failed replacement
    /// must not make a previously working capture session disappear from the
    /// lifecycle model.
    private var committedActivation: NativeEntranceActivation?
    private var committedTransaction: NativeEntranceTransaction?
    private var committedOutcome: NativeEntranceApplyOutcome?

    init(backend: any NativeEntranceLifecycleBackend) {
        self.backend = backend
        committedActivation = nil
        committedTransaction = nil
        committedOutcome = nil
    }

    @discardableResult
    func activate(
        revision: UInt64,
        enabled: Set<NativeEntranceCapability>
    ) async throws -> NativeEntranceActivation {
        guard revision > 0 else { throw NativeEntranceLifecycleError.invalidRevision }
        guard !enabled.isEmpty else { throw NativeEntranceLifecycleError.noEnabledEntrance }
        guard !enabled.isSuperset(of: [.systemProxy, .appRouting]) else {
            throw NativeEntranceLifecycleError.mutuallyExclusiveEntrances
        }
        if let current = state.activation, revision < current.revision {
            throw NativeEntranceLifecycleError.staleRevision(
                current: current.revision,
                requested: revision
            )
        }

        generation &+= 1
        let activation = NativeEntranceActivation(
            revision: revision,
            enabled: enabled,
            generation: generation
        )
        state = .activating(activation)
        do {
            let transaction = NativeEntranceTransaction(activation: activation)
            let outcome = try await backend.apply(
                transaction,
                replacing: committedTransaction
            )
            committedActivation = activation
            committedTransaction = transaction
            committedOutcome = outcome
            state = outcome == .running
                ? .active(activation)
                : .requiresReboot(activation)
            return activation
        } catch {
            if let committedActivation, let committedOutcome {
                state = committedOutcome == .running
                    ? .active(committedActivation)
                    : .requiresReboot(committedActivation)
            } else {
                state = .failed(error.localizedDescription)
            }
            throw error
        }
    }

    @discardableResult
    func activate(
        _ transaction: NativeEntranceTransaction
    ) async throws -> NativeEntranceActivationResult {
        let activation = transaction.activation
        guard activation.revision > 0 else { throw NativeEntranceLifecycleError.invalidRevision }
        guard !activation.enabled.isEmpty else { throw NativeEntranceLifecycleError.noEnabledEntrance }
        guard !activation.enabled.isSuperset(of: [.systemProxy, .appRouting]) else {
            throw NativeEntranceLifecycleError.mutuallyExclusiveEntrances
        }
        if let current = state.activation, activation.revision < current.revision {
            throw NativeEntranceLifecycleError.staleRevision(current: current.revision, requested: activation.revision)
        }
        generation = max(generation &+ 1, activation.generation)
        state = .activating(activation)
        do {
            let outcome = try await backend.apply(
                transaction,
                replacing: committedTransaction
            )
            committedActivation = activation
            committedTransaction = transaction
            committedOutcome = outcome
            state = outcome == .running
                ? .active(activation)
                : .requiresReboot(activation)
            return NativeEntranceActivationResult(
                activation: activation,
                outcome: outcome
            )
        } catch {
            if let committedActivation, let committedOutcome {
                state = committedOutcome == .running
                    ? .active(committedActivation)
                    : .requiresReboot(committedActivation)
            }
            else { state = .failed(error.localizedDescription) }
            throw error
        }
    }

    /// Deactivates the current native capture capabilities. Calling this while
    /// inactive is idempotent and does not touch a provider.
    func deactivate() async throws {
        guard let current = state.activation else {
            state = .inactive
            return
        }
        state = .deactivating(current)
        do {
            if let committedTransaction {
                try await backend.deactivate(committedTransaction)
            } else {
                try await backend.deactivate(NativeEntranceTransaction(activation: current))
            }
            committedActivation = nil
            committedTransaction = nil
            committedOutcome = nil
            state = .inactive
        } catch {
            state = .active(current)
            throw error
        }
    }
}
