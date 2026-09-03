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
    func apply(_ activation: NativeEntranceActivation) async throws
    func deactivate(_ activation: NativeEntranceActivation) async throws
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

    init(backend: any NativeEntranceLifecycleBackend) {
        self.backend = backend
        committedActivation = nil
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
            try await backend.apply(activation)
            committedActivation = activation
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

    /// Deactivates the current native capture capabilities. Calling this while
    /// inactive is idempotent and does not touch a provider.
    func deactivate() async throws {
        guard let current = state.activation else {
            state = .inactive
            return
        }
        state = .deactivating(current)
        do {
            try await backend.deactivate(current)
            committedActivation = nil
            state = .inactive
        } catch {
            state = .active(current)
            throw error
        }
    }
}
