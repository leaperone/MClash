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
                // This listener currently has an inbound-aware handshake only
                // for SOCKS5 node targets. Every other protocol remains
                // fail-closed: opening a raw endpoint would leak application
                // bytes in the wrong wire format and look like Direct.
                guard target.protocolName == "socks5" else {
                    throw NativeInboundListenerConfigurationError.unsupportedOutboundTransport(
                        route: route,
                        protocolName: target.protocolName
                    )
                }
                resolvedRoute = .proxy(route.stableSortKey)
            }
            let routeForListener = resolvedRoute
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
                route: { [routeResolver, routeForListener] destination in
                    // The catalog check above is performed transactionally
                    // during configure. The resolver still owns destination
                    // policy (for example future domain restrictions), but a
                    // proxy route can only be the exact selected route.
                    switch routeForListener {
                    case .direct, .reject:
                        return routeResolver(spec, destination)
                    case .proxy:
                        return routeForListener
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

    func establish(
        _ connection: NWConnection,
        to destination: MClashInboundDestination,
        route: MClashInboundRoute,
        completion: @escaping @Sendable (Error?) -> Void
    ) {
        guard case let .proxy(routeKey) = route,
              let entry = catalog.entries.first(where: { $0.route.stableSortKey == routeKey }),
              entry.target.protocolName == "socks5"
        else {
            completion(NativeInboundSOCKS5HandshakeError.invalidRoute)
            connection.cancel()
            return
        }

        let target = entry.target
        let username = target.parameters["username"] ?? target.parameters["user"]
        let password = target.parameters["password"] ?? target.parameters["pass"]
        let needsCredentials = username != nil || password != nil

        do {
            let methods: [SOCKS5AuthenticationMethod] = needsCredentials
                ? [.usernamePassword]
                : [.noAuthenticationRequired]
            try send(Data(try SOCKS5Codec.encodeGreeting(methods: methods)), on: connection) { error in
                guard error == nil else { completion(error); return }
                self.receiveExact(2, from: connection, buffer: Data()) { methodData, error in
                    if let error { completion(error); return }
                    do {
                        let selected = try SOCKS5Codec.decodeMethodSelection(methodData)
                        guard selected.method == (needsCredentials ? .usernamePassword : .noAuthenticationRequired) else {
                            throw NativeInboundSOCKS5HandshakeError.serverSelectedUnexpectedMethod(selected.method.rawValue)
                        }
                        if needsCredentials {
                            guard let username, let password else { throw NativeInboundSOCKS5HandshakeError.missingCredentials }
                            let credentials = try SOCKS5UsernamePasswordCredentials(username: username, password: password)
                            try self.send(
                                SOCKS5Codec.encodeUsernamePasswordRequest(credentials: credentials),
                                on: connection
                            ) { error in
                                guard error == nil else { completion(error); return }
                                self.receiveExact(2, from: connection, buffer: Data()) { authData, error in
                                    do {
                                        if let error { throw error }
                                        try SOCKS5Codec.decodeUsernamePasswordResponse(authData).requireSuccess()
                                        try self.sendCommand(destination, on: connection, completion: completion)
                                    } catch { completion(error); connection.cancel() }
                                }
                            }
                        } else {
                            try self.sendCommand(destination, on: connection, completion: completion)
                        }
                    } catch { completion(error); connection.cancel() }
                }
            }
        } catch { completion(error); connection.cancel() }
    }

    private func send(
        _ data: Data,
        on connection: NWConnection,
        completion: @escaping @Sendable (Error?) -> Void
    ) throws {
        connection.send(content: data, completion: .contentProcessed(completion))
    }

    private func sendCommand(
        _ destination: MClashInboundDestination,
        on connection: NWConnection,
        completion: @escaping @Sendable (Error?) -> Void
    ) throws {
        let endpoint = try SOCKS5Endpoint(address: SOCKS5Address(domain: destination.host), port: destination.port)
        let request = try SOCKS5CommandRequest(command: .connect, endpoint: endpoint)
        try send(SOCKS5Codec.encodeCommandRequest(request), on: connection) { [weak connection] error in
            guard let connection else { completion(error); return }
            guard error == nil else { completion(error); return }
            self.receiveReply(from: connection, buffer: Data(), completion: completion)
        }
    }

    private func receiveExact(
        _ count: Int,
        from connection: NWConnection?,
        buffer: Data,
        completion: @escaping @Sendable (Data, Error?) -> Void
    ) {
        guard let connection else {
            completion(buffer, NativeInboundSOCKS5HandshakeError.connectionUnavailable)
            return
        }
        connection.receive(minimumIncompleteLength: max(1, count - buffer.count), maximumLength: count - buffer.count) { [weak connection] data, _, complete, error in
            var next = buffer
            if let data { next.append(data) }
            if let error { completion(next, error); return }
            if next.count >= count { completion(Data(next.prefix(count)), nil); return }
            if complete { completion(next, NativeInboundSOCKS5HandshakeError.truncatedResponse); return }
            self.receiveExact(count, from: connection, buffer: next, completion: completion)
        }
    }

    private func receiveReply(
        from connection: NWConnection,
        buffer: Data,
        completion: @escaping @Sendable (Error?) -> Void
    ) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: SOCKS5Limits.maximumStreamInputBytes) { [weak connection] data, _, complete, error in
            guard let connection else {
                completion(NativeInboundSOCKS5HandshakeError.connectionUnavailable)
                return
            }
            var next = buffer
            if let data { next.append(data) }
            do {
                guard let length = try SOCKS5Codec.commandReplyFrameLength(Array(next)) else {
                    if complete { throw NativeInboundSOCKS5HandshakeError.truncatedResponse }
                    self.receiveReply(from: connection, buffer: next, completion: completion)
                    return
                }
                guard next.count >= length else {
                    if complete { throw NativeInboundSOCKS5HandshakeError.truncatedResponse }
                    self.receiveReply(from: connection, buffer: next, completion: completion)
                    return
                }
                try SOCKS5Codec.decodeCommandReply(Data(next.prefix(length))).requireSuccess()
                completion(nil)
            } catch {
                completion(error)
                connection.cancel()
            }
        }
    }
}

enum NativeInboundSOCKS5HandshakeError: Error, Equatable, Sendable {
    case invalidRoute
    case missingCredentials
    case serverSelectedUnexpectedMethod(UInt8)
    case truncatedResponse
    case connectionUnavailable
}
