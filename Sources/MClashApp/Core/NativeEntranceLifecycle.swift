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

    init(
        activation: NativeEntranceActivation,
        runtimeConfiguration: NetworkExtensionRuntimeConfiguration? = nil,
        systemProxyEndpoints: LocalSystemProxyEndpoints? = nil,
        systemProxySnapshot: SystemProxySnapshot? = nil,
        rollbackToken: Data? = nil
    ) {
        self.activation = activation
        self.runtimeConfiguration = runtimeConfiguration
        self.systemProxyEndpoints = systemProxyEndpoints
        self.systemProxySnapshot = systemProxySnapshot
        self.rollbackToken = rollbackToken
    }
}

enum NativeEntranceLifecycleState: Equatable, Sendable {
    case inactive
    case activating(NativeEntranceActivation)
    case active(NativeEntranceActivation)
    case deactivating(NativeEntranceActivation)
    case failed(String)

    var activation: NativeEntranceActivation? {
        switch self {
        case let .activating(value), let .active(value), let .deactivating(value):
            return value
        case .inactive, .failed:
            return nil
        }
    }
}

enum NativeEntranceLifecycleError: Error, Equatable, LocalizedError, Sendable {
    case invalidRevision
    case noEnabledEntrance
    case staleRevision(current: UInt64, requested: UInt64)

    var errorDescription: String? {
        switch self {
        case .invalidRevision:
            "Native entrance activation requires a non-zero revision."
        case .noEnabledEntrance:
            "Native entrance activation requires at least one enabled entrance."
        case let .staleRevision(current, requested):
            "Native entrance revision \(requested) is older than the active revision \(current)."
        }
    }
}

/// Side-effect boundary for capture providers. Implementations may be backed
/// by NetworkExtension/SystemConfiguration, while tests use an in-memory
/// backend. No implementation is allowed to invoke a Mihomo controller.
protocol NativeEntranceLifecycleBackend: Sendable {
    func apply(_ transaction: NativeEntranceTransaction) async throws
    func deactivate(_ transaction: NativeEntranceTransaction) async throws
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

    init(backend: any NativeEntranceLifecycleBackend) {
        self.backend = backend
        committedActivation = nil
        committedTransaction = nil
    }

    @discardableResult
    func activate(
        revision: UInt64,
        enabled: Set<NativeEntranceCapability>
    ) async throws -> NativeEntranceActivation {
        guard revision > 0 else { throw NativeEntranceLifecycleError.invalidRevision }
        guard !enabled.isEmpty else { throw NativeEntranceLifecycleError.noEnabledEntrance }
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
            try await backend.apply(NativeEntranceTransaction(activation: activation))
            committedActivation = activation
            committedTransaction = NativeEntranceTransaction(activation: activation)
            state = .active(activation)
            return activation
        } catch {
            if let committedActivation {
                state = .active(committedActivation)
            } else {
                state = .failed(error.localizedDescription)
            }
            throw error
        }
    }

    @discardableResult
    func activate(_ transaction: NativeEntranceTransaction) async throws -> NativeEntranceActivation {
        let activation = transaction.activation
        guard activation.revision > 0 else { throw NativeEntranceLifecycleError.invalidRevision }
        guard !activation.enabled.isEmpty else { throw NativeEntranceLifecycleError.noEnabledEntrance }
        if let current = state.activation, activation.revision < current.revision {
            throw NativeEntranceLifecycleError.staleRevision(current: current.revision, requested: activation.revision)
        }
        generation = max(generation &+ 1, activation.generation)
        state = .activating(activation)
        do {
            try await backend.apply(transaction)
            committedActivation = activation
            committedTransaction = transaction
            state = .active(activation)
            return activation
        } catch {
            if let committedActivation { state = .active(committedActivation) }
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
            state = .inactive
        } catch {
            state = .active(current)
            throw error
        }
    }
}
