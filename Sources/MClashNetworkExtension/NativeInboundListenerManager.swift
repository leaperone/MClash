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

enum NativeInboundListenerConfigurationError: Error, Equatable, Sendable {
    case missingOutboundTarget(OutboundRoute)
    case unsupportedOutboundProtocol(route: OutboundRoute, protocolName: String)
    case unsupportedOutboundTransport(route: OutboundRoute, protocolName: String)
}

extension NativeInboundListenerConfigurationError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case let .missingOutboundTarget(route):
            return "Native listener route has no node target: \(route.stableSortKey)."
        case let .unsupportedOutboundProtocol(route, protocolName):
            return "Native listener route \(route.stableSortKey) uses unsupported outbound protocol \(protocolName)."
        case let .unsupportedOutboundTransport(route, protocolName):
            return "Native listener route \(route.stableSortKey) uses an unsupported \(protocolName) transport."
        }
    }
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
    func configure(
        _ newRegistry: MClashListenerRegistry,
        outboundCatalog: OutboundNodeTargetCatalog? = nil,
        outboundConnector: (any MClashInboundOutboundConnector)? = nil
    ) throws {
        stop()
        let activeConnector = outboundConnector ?? connector
        var newListeners: [UUID: MClashInboundListener] = [:]
        var newStates: [UUID: NativeInboundListenerState] = [:]
        for spec in newRegistry.enabledListeners where spec.kind.requiresSocketEndpoint {
            guard let port = spec.port else { continue }
            let resolvedRoute: MClashInboundRoute
            switch spec.route {
            case .direct:
                resolvedRoute = .direct
            case .reject:
                resolvedRoute = .reject
            case let .outbound(route):
                guard let target = outboundCatalog?.target(for: route) else {
                    // A proxy entrance without a concrete target is a
                    // configuration error. It must never silently turn into
                    // Direct (or an unrelated legacy endpoint).
                    throw NativeInboundListenerConfigurationError.missingOutboundTarget(route)
                }
                guard NativeConnectorRegistry.supports(target) else {
                    throw NativeInboundListenerConfigurationError.unsupportedOutboundProtocol(
                        route: route,
                        protocolName: target.protocolName
                    )
                }
                // Native inbound listeners need a connector that owns the
                // complete protocol handshake. The current catalog adapter
                // only resolves endpoint material; it must not open a raw
                // TCP socket for SOCKS5/HTTP/VLESS/Trojan/SS (that would send
                // application bytes in the wrong protocol and look like a
                // successful Direct fallback). Keep this entrance disabled
                // until an inbound-aware connector is wired for the target.
                throw NativeInboundListenerConfigurationError.unsupportedOutboundTransport(
                    route: route,
                    protocolName: target.protocolName
                )
            }
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
                    // The catalog check above is performed transactionally
                    // during configure. The resolver still owns destination
                    // policy (for example future domain restrictions), but a
                    // proxy route can only be the exact selected route.
                    switch resolvedRoute {
                    case .direct, .reject:
                        return routeResolver(spec, destination)
                    case .proxy:
                        return resolvedRoute
                    }
                },
                connector: activeConnector,
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

/// Connector-neutral native catalog adapter used by MClash-owned HTTP/SOCKS
/// entrances. The listener passes an exact stable route key; this adapter
/// resolves that key to a node target and opens the transport endpoint. The
/// protocol-specific handshake is deliberately owned by the native connector
/// layer, never by the routing policy or by a Mihomo listener.
struct NativeInboundCatalogConnector: MClashInboundOutboundConnector {
    let catalog: OutboundNodeTargetCatalog

    func connect(to destination: MClashInboundDestination, route: MClashInboundRoute) -> NWConnection {
        guard case let .proxy(routeKey) = route,
              let entry = catalog.entries.first(where: { $0.route.stableSortKey == routeKey }),
              NativeConnectorRegistry.supportsNativeTCP(entry.target)
        else {
            // The manager rejects this path during configure. Keep a
            // fail-closed endpoint here for races or malformed callers; do
            // not substitute Direct.
            return NWConnection(
                host: NWEndpoint.Host("127.0.0.1"),
                port: NWEndpoint.Port(rawValue: 1)!,
                using: .tcp
            )
        }
        return NWConnection(
            host: NWEndpoint.Host(entry.target.host),
            port: NWEndpoint.Port(rawValue: entry.target.port)!,
            using: .tcp
        )
    }
}
