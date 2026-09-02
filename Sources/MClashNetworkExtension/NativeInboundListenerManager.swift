import Foundation
@preconcurrency import Network
import MClashNetworkShared

/// Observable lifecycle for an MClash-owned socket entrance.  This is kept
/// separate from the transparent provider's flow state so a listener reload
/// can be tested and stopped transactionally.
enum NativeInboundListenerState: Equatable, Sendable {
    case stopped
    case starting
    case running(port: UInt16)
    case failed
}

/// Owns the concrete HTTP/SOCKS listeners for the native runtime.  It is
/// deliberately opt-in at the caller: constructing this manager never binds
/// a socket, and `start()` only starts listeners supplied by `configure`.
final class NativeInboundListenerManager: @unchecked Sendable {
    private let lock = NSLock()
    private var listeners: [UUID: MClashInboundListener] = [:]
    private var states: [UUID: NativeInboundListenerState] = [:]
    private var registry: MClashListenerRegistry?
    private let routeResolver: @Sendable (MClashListenerSpec, MClashInboundDestination) -> MClashInboundRoute
    private let connector: MClashInboundOutboundConnector

    init(
        routeResolver: @escaping @Sendable (MClashListenerSpec, MClashInboundDestination) -> MClashInboundRoute,
        connector: MClashInboundOutboundConnector
    ) {
        self.routeResolver = routeResolver
        self.connector = connector
    }

    /// Replaces the native entrance registry. Existing sockets are cancelled
    /// before the replacement is installed, so a reload cannot leave a stale
    /// port alive. Disabled/system-only entrances have observable stopped
    /// state but do not create a TCP listener.
    func configure(_ newRegistry: MClashListenerRegistry) throws {
        stop()
        var newListeners: [UUID: MClashInboundListener] = [:]
        var newStates: [UUID: NativeInboundListenerState] = [:]
        for spec in newRegistry.enabledListeners where spec.kind.requiresSocketEndpoint {
            guard let port = spec.port else { continue }
            let kind: MClashInboundListener.Kind?
            switch spec.kind {
            case .http: kind = .httpConnect
            case .socks5: kind = .socks5
            case .appRouting, .tun: kind = nil
            }
            guard let kind else { continue }
            let listener = try MClashInboundListener(
                kind: kind,
                port: port,
                route: { [routeResolver] destination in
                    routeResolver(spec, destination)
                },
                connector: connector,
                stateHandler: { [weak self] ready, actualPort in
                    self?.listenerStateChanged(id: spec.id, ready: ready, port: actualPort)
                }
            )
            newListeners[spec.id] = listener
            newStates[spec.id] = .stopped
        }
        lock.lock()
        registry = newRegistry
        listeners = newListeners
        states = Dictionary(uniqueKeysWithValues: newRegistry.listeners.map {
            ($0.id, newStates[$0.id] ?? .stopped)
        })
        lock.unlock()
    }

    func start() {
        lock.lock()
        let entries = listeners
        for id in entries.keys { states[id] = .starting }
        lock.unlock()
        for (id, listener) in entries {
            listener.start()
            // The callback promotes this to running once NWListener is ready.
            // Keeping starting visible avoids claiming a bound port early.
            _ = id
        }
    }

    func stop() {
        lock.lock()
        let entries = listeners
        listeners.removeAll()
        for id in states.keys { states[id] = .stopped }
        lock.unlock()
        entries.values.forEach { $0.stop() }
    }

    func lifecycleStates() -> [UUID: NativeInboundListenerState] {
        lock.lock(); defer { lock.unlock() }
        return states
    }

    func configuredRegistry() -> MClashListenerRegistry? {
        lock.lock(); defer { lock.unlock() }
        return registry
    }

    private func listenerStateChanged(id: UUID, ready: Bool, port: UInt16?) {
        lock.lock(); defer { lock.unlock() }
        guard listeners[id] != nil else { return }
        states[id] = ready ? .running(port: port ?? 0) : .stopped
    }
}

/// Safe connector used by the opt-in provider bridge until a route-specific
/// native outbound catalog is available. Proxy routes are rejected by the
/// provider route hook; they must never silently become Direct.
struct NativeInboundDirectConnector: MClashInboundOutboundConnector {
    func connect(to destination: MClashInboundDestination, route: MClashInboundRoute) -> NWConnection {
        NWConnection(
            host: NWEndpoint.Host(destination.host),
            port: NWEndpoint.Port(rawValue: destination.port)!,
            using: .tcp
        )
    }
}
