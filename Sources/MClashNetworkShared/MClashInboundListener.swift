import Foundation
@preconcurrency import Network

/// A destination presented by an MClash-owned TCP entrance.
public struct MClashInboundDestination: Equatable, Sendable {
    public let host: String
    public let port: UInt16
    public init(host: String, port: UInt16) { self.host = host; self.port = port }
}

private extension SOCKS5Endpoint {
    var networkHost: NWEndpoint.Host? {
        if let address = address.ipAddress?.presentation { return NWEndpoint.Host(address) }
        if let domain = address.domain { return NWEndpoint.Host(domain) }
        return nil
    }
    var networkPort: NWEndpoint.Port? { NWEndpoint.Port(rawValue: port) }
}

public enum MClashInboundRoute: Equatable, Sendable {
    case direct
    case reject
    case proxy(String)
}

/// Outbound connection boundary for the MClash-owned listener.  The listener
/// never knows whether a proxy connection is backed by Mihomo, Xray, or a
/// future native connector.
public protocol MClashInboundOutboundConnector: Sendable {
    func connect(to destination: MClashInboundDestination, route: MClashInboundRoute) -> NWConnection

    /// Returns the per-upstream transport codec used after establishment. A
    /// codec is deliberately created for each connection: WebSocket framing
    /// has receive state, while plain TCP transports use the identity default.
    func makeBridgeCodec(
        to destination: MClashInboundDestination,
        route: MClashInboundRoute
    ) throws -> (any MClashInboundBridgeCodec)?

    func makeBridgeCodec(
        for connection: NWConnection,
        to destination: MClashInboundDestination,
        route: MClashInboundRoute
    ) throws -> (any MClashInboundBridgeCodec)?

    /// Completes any protocol handshake required by the selected outbound
    /// transport. The completion must only succeed once the upstream is ready
    /// to carry application bytes. The default is used by DIRECT and test
    /// connectors which have no transport preamble.
    func establish(
        _ connection: NWConnection,
        to destination: MClashInboundDestination,
        route: MClashInboundRoute,
        completion: @escaping @Sendable (Error?) -> Void
    )

    /// Completes establishment and returns bytes already read after the
    /// protocol response header. TCP stacks may coalesce the first payload
    /// with CONNECT/SOCKS success; dropping it corrupts the application flow.
    func establishWithInitialPayload(
        _ connection: NWConnection,
        to destination: MClashInboundDestination,
        route: MClashInboundRoute,
        completion: @escaping @Sendable (Error?, Data) -> Void
    )
}

/// Adapts application bytes to and from a transport framing layer. Returning
/// nil means the transport is a plain byte stream. Implementations must own
/// their mutable decoder state and must be safe to use from the listener's
/// serial queue only.
public protocol MClashInboundBridgeCodec: AnyObject, Sendable {
    func encode(_ payload: Data) throws -> Data
    func decode(_ input: Data) throws -> [Data]
    func finishEncoding() throws -> Data?
}

public extension MClashInboundBridgeCodec {
    func finishEncoding() throws -> Data? { nil }
}

public extension MClashInboundOutboundConnector {
    func makeBridgeCodec(
        to _: MClashInboundDestination,
        route _: MClashInboundRoute
    ) throws -> (any MClashInboundBridgeCodec)? { nil }

    func makeBridgeCodec(
        for _: NWConnection,
        to destination: MClashInboundDestination,
        route: MClashInboundRoute
    ) throws -> (any MClashInboundBridgeCodec)? {
        try makeBridgeCodec(to: destination, route: route)
    }

    func establish(
        _ connection: NWConnection,
        to destination: MClashInboundDestination,
        route: MClashInboundRoute,
        completion: @escaping @Sendable (Error?) -> Void
    ) {
        _ = connection; _ = destination; _ = route
        completion(nil)
    }

    func establishWithInitialPayload(
        _ connection: NWConnection,
        to destination: MClashInboundDestination,
        route: MClashInboundRoute,
        completion: @escaping @Sendable (Error?, Data) -> Void
    ) {
        establish(connection, to: destination, route: route) { error in
            completion(error, Data())
        }
    }
}

/// Minimal HTTP CONNECT/SOCKS5 TCP server owned by MClash.  It deliberately
/// contains no routing policy: callers supply `route` and a connector. This
/// makes the protocol surface independently testable before AppModel wiring.
public final class MClashInboundListener: @unchecked Sendable {
    public enum Kind: Sendable { case httpConnect, socks5 }

    let kind: Kind
    private let queue: DispatchQueue
    private let routing: MClashInboundRoutingState
    private let stateHandler: (@Sendable (Bool, UInt16?) -> Void)?
    private let failureHandler: (@Sendable (String) -> Void)?
    private let observationHandler: (@Sendable (FlowRelayObservation) -> Void)?
    private let entranceName: String
    private var listener: NWListener?
    private var connections = [ObjectIdentifier: NWConnection]()
    private var flowMeters = [ObjectIdentifier: NativeFlowObservationMeter]()
    public private(set) var port: UInt16?

    public init(kind: Kind, bindAddress: String = "127.0.0.1", port: UInt16 = 0, queue: DispatchQueue = DispatchQueue(label: "one.leaper.mclash.inbound"), route: @escaping @Sendable (MClashInboundDestination) -> MClashInboundRoute, connector: MClashInboundOutboundConnector, stateHandler: (@Sendable (Bool, UInt16?) -> Void)? = nil, failureHandler: (@Sendable (String) -> Void)? = nil, entranceName: String = "MClash", observationHandler: (@Sendable (FlowRelayObservation) -> Void)? = nil) throws {
        self.kind = kind; self.queue = queue; routing = MClashInboundRoutingState(route: route, connector: connector); self.stateHandler = stateHandler; self.failureHandler = failureHandler; self.entranceName = entranceName; self.observationHandler = observationHandler
        guard MClashListenerSpec.isLoopback(bindAddress) else {
            throw MClashListenerRegistryError.nonLoopbackBindAddress(bindAddress)
        }
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(
            host: NWEndpoint.Host(bindAddress),
            port: NWEndpoint.Port(rawValue: port)!
        )
        let nwListener = try NWListener(using: parameters)
        listener = nwListener
        nwListener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
    }

    public func start() {
        queue.async(execute: DispatchWorkItem { [weak self] in
            guard let self, let listener = self.listener else { return }
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    self.port = listener.port?.rawValue
                    self.stateHandler?(true, self.port)
                case .failed, .cancelled:
                    self.stateHandler?(false, nil)
                default:
                    break
                }
            }
            listener.start(queue: queue)
        })
    }

    /// Atomically changes policy and connector selection without rebinding the
    /// listening socket. Existing flows retain their captured connector while
    /// newly accepted flows use the new runtime-plan generation.
    public func reconfigure(
        route: @escaping @Sendable (MClashInboundDestination) -> MClashInboundRoute,
        connector: MClashInboundOutboundConnector
    ) {
        routing.update(route: route, connector: connector)
    }

    public func stop() {
        queue.async(execute: DispatchWorkItem { [weak self] in
            guard let self else { return }
            listener?.cancel(); listener = nil
            flowMeters.values.forEach { $0.finishOnCancellation() }
            flowMeters.removeAll()
            connections.values.forEach { $0.cancel() }; connections.removeAll(); port = nil
            stateHandler?(false, nil)
        })
    }

    private func accept(_ connection: NWConnection) {
        queue.async { [weak self, connection] in
            guard let self else { connection.cancel(); return }
            connections[ObjectIdentifier(connection)] = connection
            connection.stateUpdateHandler = { [weak self, weak connection] state in
                guard let self, let connection else { return }
                switch state {
                case .failed:
                    self.queue.async {
                        let identifier = ObjectIdentifier(connection)
                        self.flowMeters.removeValue(forKey: identifier)?
                            .fail(reason: "Entrance connection failed")
                        self.connections.removeValue(forKey: identifier)
                    }
                case .cancelled:
                    self.queue.async {
                        let identifier = ObjectIdentifier(connection)
                        self.flowMeters.removeValue(forKey: identifier)?
                            .finishOnCancellation()
                        self.connections.removeValue(forKey: identifier)
                    }
                default:
                    break
                }
            }
            connection.start(queue: queue)
            switch kind { case .httpConnect: self.readHTTP(connection, buffer: Data()); case .socks5: self.readSOCKSGreeting(connection, buffer: Data()) }
        }
    }

    private func readHTTP(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: HTTPProxyCodec.maximumHeaderBytes) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var next = buffer; if let data { next.append(data) }
            if let error { connection.cancel(); _ = error; return }
            if let end = next.range(of: Data("\r\n\r\n".utf8)) {
                do { let request = try HTTPProxyCodec.decodeConnectRequest(next); self.open(connection, destination: .init(host: request.host, port: request.port), response: HTTPProxyCodec.encodeEstablishedResponse()) }
                catch { connection.send(content: HTTPProxyCodec.encodeFailureResponse(status: 400, reason: "Bad Request"), completion: .contentProcessed { _ in connection.cancel() }) }
                _ = end
            } else if next.count < HTTPProxyCodec.maximumHeaderBytes && !isComplete { self.readHTTP(connection, buffer: next) } else { connection.cancel() }
        }
    }

    private func readSOCKSGreeting(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 2) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var next = buffer; if let data { next.append(data) }
            if error != nil || isComplete && next.count < 2 { connection.cancel(); return }
            guard next.count >= 2 else { self.readSOCKSGreeting(connection, buffer: next); return }
            do { _ = try SOCKS5Codec.decodeMethodSelection(Data(next.prefix(2))); guard next[1] == 0 else { throw SOCKS5CodecError.noAcceptableAuthenticationMethods }; connection.send(content: Data([5, 0]), completion: .contentProcessed { [weak self] _ in self?.readSOCKSCommand(connection, buffer: Data()) }) }
            catch { connection.send(content: Data([5, 0xff]), completion: .contentProcessed { _ in connection.cancel() }) }
        }
    }

    private func readSOCKSCommand(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: SOCKS5Limits.maximumStreamInputBytes) { [weak self] data, _, isComplete, error in
            guard let self else { return }; var next = buffer; if let data { next.append(data) }
            if error != nil { connection.cancel(); return }
            do {
                guard let length = try SOCKS5Codec.commandRequestFrameLength(Array(next)), next.count >= length else { if isComplete { connection.cancel() } else { self.readSOCKSCommand(connection, buffer: next) }; return }
                let request = try SOCKS5Codec.decodeCommandRequest(Data(next.prefix(length)))
                guard request.command == .connect else { connection.send(content: Self.socksReply(.commandNotSupported), completion: .contentProcessed { _ in connection.cancel() }); return }
                let endpoint = request.endpoint
                let host: String?
                if let address = endpoint.address.ipAddress?.presentation { host = address }
                else { host = endpoint.address.domain }
                guard let host, endpoint.port > 0 else { connection.cancel(); return }
                self.open(connection, destination: .init(host: host, port: endpoint.port), response: Data([5, 0, 0, 1, 0, 0, 0, 0, 0, 0]))
            } catch { connection.cancel() }
        }
    }

    private func open(_ client: NWConnection, destination: MClashInboundDestination, response: Data) {
        let routing = routing.snapshot()
        let decision = routing.route(destination)
        let connector = routing.connector
        let flowID = UUID().uuidString
        let meter = NativeFlowObservationMeter(id: flowID, startedAt: Date(), network: kind == .httpConnect ? "tcp/http" : "tcp/socks5", destination: destination, entranceName: entranceName, route: decision == .direct ? .direct : .relay, routeChain: { if case let .proxy(key) = decision { return [key] }; return [] }(), emit: observationHandler)
        guard decision != .reject else {
            observationHandler?(FlowRelayObservation(id: flowID, startedAt: Date(), endedAt: Date(), network: kind == .httpConnect ? "tcp/http" : "tcp/socks5", destinationHost: destination.host, destinationPort: destination.port, inboundName: entranceName, connector: "native", state: .rejected, route: .rejected))
            let rejection = response.starts(with: Data("HTTP/".utf8)) ? HTTPProxyCodec.encodeFailureResponse(status: 403, reason: "Forbidden") : Self.socksReply(.connectionNotAllowed)
            client.send(content: rejection, completion: .contentProcessed { _ in client.cancel() }); return
        }
        flowMeters[ObjectIdentifier(client)] = meter
        let upstream: NWConnection
        switch decision { case .direct: upstream = NWConnection(host: NWEndpoint.Host(destination.host), port: NWEndpoint.Port(rawValue: destination.port)!, using: .tcp); case .proxy: upstream = connector.connect(to: destination, route: decision); case .reject: return }
        // Establish the upstream before acknowledging CONNECT/ SOCKS5. This
        // prevents clients from believing a route is usable while the native
        // connector is still resolving or has already failed.
        upstream.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                connector.establishWithInitialPayload(
                    upstream,
                    to: destination,
                    route: decision
                ) { error, initialPayload in
                    guard error == nil else {
                        meter.fail(reason: "Outbound establishment failed")
                        self.reportFailure(error, context: "outbound establishment")
                        client.cancel(); upstream.cancel(); return
                    }
                    client.send(content: response, completion: .contentProcessed { error in
                        guard error == nil else { meter.fail(reason: "Entrance response failed"); client.cancel(); upstream.cancel(); return }
                        do {
                            let codec = try connector.makeBridgeCodec(
                                for: upstream,
                                to: destination,
                                route: decision
                            )
                            meter.emit(state: .active)
                            self.bridge(client, upstream, codec: codec, initialUpstreamPayload: initialPayload, meter: meter)
                        } catch {
                            meter.fail(reason: "Bridge setup failed")
                            self.reportFailure(error, context: "bridge setup")
                            client.cancel(); upstream.cancel()
                        }
                    })
                }
            case let .failed(error):
                meter.fail(reason: "Upstream connection failed")
                self.reportFailure(error, context: "upstream connection")
                client.cancel()
            case .cancelled:
                meter.finishOnCancellation()
                client.cancel()
            default:
                break
            }
        }
        upstream.start(queue: queue)
    }

    private func bridge(
        _ a: NWConnection,
        _ b: NWConnection,
        codec: (any MClashInboundBridgeCodec)?,
        initialUpstreamPayload: Data = Data(),
        meter: NativeFlowObservationMeter
    ) {
        let completion = NativeBridgeCompletionState(
            client: a,
            upstream: b,
            meter: meter
        )
        let upstreamToClient: @Sendable () -> Void = {
            self.pump(from: b, to: a, transform: { data in
                guard let codec else { return [data] }
                return try codec.decode(data)
            }, deliveredByteCount: { _, chunks in
                chunks.reduce(0) { $0 + $1.count }
            }, delivered: { meter.addDownload($0) }, terminal: {
                completion.halfClose(target: a, download: true)
            }, failure: completion.fail)
        }
        if !initialUpstreamPayload.isEmpty {
            do {
                let chunks = try codec.map { try $0.decode(initialUpstreamPayload) } ?? [initialUpstreamPayload]
                send(
                    chunks,
                    index: 0,
                    from: b,
                    to: a,
                    transform: { data in [data] },
                    then: upstreamToClient,
                    delivered: { meter.addDownload($0) },
                    failure: completion.fail
                )
            } catch {
                reportFailure(error, context: "initial bridge transform")
                completion.fail(error)
                return
            }
        } else {
            upstreamToClient()
        }
        pump(from: a, to: b, transform: { data in
            guard let codec else { return [data] }
            return [try codec.encode(data)]
        }, deliveredByteCount: { input, _ in input.count }, delivered: {
            meter.addUpload($0)
        }, terminal: {
            do {
                completion.halfClose(
                    target: b,
                    download: false,
                    finalPayload: try codec?.finishEncoding()
                )
            } catch {
                completion.fail(error)
            }
        }, failure: completion.fail)
    }
    private func pump(
        from source: NWConnection,
        to target: NWConnection,
        transform: @escaping @Sendable (Data) throws -> [Data],
        deliveredByteCount: @escaping @Sendable (Data, [Data]) -> Int,
        delivered: (@Sendable (Int) -> Void)? = nil,
        terminal: (@Sendable () -> Void)? = nil,
        failure: (@Sendable (Error) -> Void)? = nil
    ) {
        source.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, complete, error in
            guard let self else { return }
            if let error {
                failure?(error)
                return
            }
            guard let data, !data.isEmpty else {
                if complete {
                    terminal?()
                } else {
                    self.pump(
                        from: source,
                        to: target,
                        transform: transform,
                        deliveredByteCount: deliveredByteCount,
                        delivered: delivered,
                        terminal: terminal,
                        failure: failure
                    )
                }
                return
            }
            do {
                let transformed = try transform(data)
                let byteCount = max(0, deliveredByteCount(data, transformed))
                send(transformed, index: 0, from: source, to: target, transform: transform, then: {
                    delivered?(byteCount)
                    self.pump(
                        from: source,
                        to: target,
                        transform: transform,
                        deliveredByteCount: deliveredByteCount,
                        delivered: delivered,
                        terminal: terminal,
                        failure: failure
                    )
                }, failure: failure)
            } catch {
                reportFailure(error, context: "bridge transform")
                failure?(error)
            }
        }
    }

    private func send(
        _ chunks: [Data],
        index: Int,
        from source: NWConnection,
        to target: NWConnection,
        transform: @escaping @Sendable (Data) throws -> [Data]
    ) {
        send(chunks, index: index, from: source, to: target, transform: transform, then: nil)
    }

    private func send(
        _ chunks: [Data],
        index: Int,
        from source: NWConnection,
        to target: NWConnection,
        transform: @escaping @Sendable (Data) throws -> [Data],
        then completion: (@Sendable () -> Void)? = nil,
        delivered: (@Sendable (Int) -> Void)? = nil,
        terminal: (@Sendable () -> Void)? = nil,
        failure: (@Sendable (Error) -> Void)? = nil
    ) {
        guard index < chunks.count else {
            delivered?(chunks.reduce(0) { $0 + $1.count })
            if let completion { completion() } else {
                pump(
                    from: source,
                    to: target,
                    transform: transform,
                    deliveredByteCount: { input, _ in input.count },
                    delivered: delivered,
                    terminal: terminal,
                    failure: failure
                )
            }
            return
        }
        target.send(content: chunks[index], completion: .contentProcessed { [weak self] error in
            guard let self, error == nil else {
                if let error { self?.reportFailure(error, context: "bridge send") }
                if let error { failure?(error) }
                else { source.cancel(); target.cancel() }
                return
            }
            self.send(chunks, index: index + 1, from: source, to: target, transform: transform, then: completion, delivered: delivered, terminal: terminal, failure: failure)
        })
    }

    private func reportFailure(_ error: Error?, context: String) {
        guard let error else { return }
        let detail = "\(context): \(String(reflecting: error))"
        failureHandler?(String(detail.prefix(512)))
    }

private static func socksReply(_ code: SOCKS5ReplyCode) -> Data { Data([5, code.rawValue, 0, 1, 0, 0, 0, 0, 0, 0]) }
}

private final class NativeFlowObservationMeter: @unchecked Sendable {
    private let lock = NSLock()
    private var upload: UInt64 = 0
    private var download: UInt64 = 0
    private var terminalState: FlowRelayObservation.State?
    private var activeStarted = false
    private let id: String
    private let startedAt: Date
    private let network: String
    private let destination: MClashInboundDestination
    private let entranceName: String
    private let route: FlowRelayObservation.Route
    private let routeChain: [String]
    private let emitHandler: (@Sendable (FlowRelayObservation) -> Void)?
    init(id: String, startedAt: Date, network: String, destination: MClashInboundDestination, entranceName: String, route: FlowRelayObservation.Route, routeChain: [String], emit: (@Sendable (FlowRelayObservation) -> Void)?) {
        self.id = id; self.startedAt = startedAt; self.network = network; self.destination = destination; self.entranceName = entranceName; self.route = route; self.routeChain = routeChain; emitHandler = emit
    }
    func addUpload(_ count: Int) { update(upload: count, download: 0) }
    func addDownload(_ count: Int) { update(upload: 0, download: count) }
    func emit(state: FlowRelayObservation.State) {
        lock.lock(); if terminalState != nil && state == .active { lock.unlock(); return }; if state == .active { activeStarted = true } else { guard terminalState == nil else { lock.unlock(); return }; terminalState = state }; let up = upload, down = download; lock.unlock()
        emitHandler?(FlowRelayObservation(id: id, startedAt: startedAt, endedAt: state == .active ? nil : Date(), network: network, destinationHost: destination.host, destinationPort: destination.port, inboundName: entranceName, routeChain: routeChain, connector: "native", uploadBytes: up, downloadBytes: down, state: state, route: route))
    }
    func finishOnCancellation() {
        lock.lock()
        let state: FlowRelayObservation.State = activeStarted ? .completed : .failed
        lock.unlock()
        emit(state: state)
    }
    func fail(reason: String) {
        emit(state: .failed, failureReason: reason)
    }
    private func emit(
        state: FlowRelayObservation.State,
        failureReason: String?
    ) {
        lock.lock(); if terminalState != nil && state == .active { lock.unlock(); return }; if state == .active { activeStarted = true } else { guard terminalState == nil else { lock.unlock(); return }; terminalState = state }; let up = upload, down = download; lock.unlock()
        emitHandler?(FlowRelayObservation(id: id, startedAt: startedAt, endedAt: state == .active ? nil : Date(), network: network, destinationHost: destination.host, destinationPort: destination.port, inboundName: entranceName, routeChain: routeChain, connector: "native", uploadBytes: up, downloadBytes: down, state: state, route: route, failureReason: failureReason))
    }
    private func update(upload: Int, download: Int) {
        lock.lock()
        guard terminalState == nil else { lock.unlock(); return }
        self.upload = Self.saturatingAdd(self.upload, UInt64(max(0, upload)))
        self.download = Self.saturatingAdd(self.download, UInt64(max(0, download)))
        let up = self.upload, down = self.download
        lock.unlock()
        emitHandler?(FlowRelayObservation(id: id, startedAt: startedAt, network: network, destinationHost: destination.host, destinationPort: destination.port, inboundName: entranceName, routeChain: routeChain, connector: "native", uploadBytes: up, downloadBytes: down, state: .active, route: route))
    }
    private static func saturatingAdd(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
        let (value, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? .max : value
    }
}

private final class NativeBridgeCompletionState: @unchecked Sendable {
    private let lock = NSLock()
    private let client: NWConnection
    private let upstream: NWConnection
    private let meter: NativeFlowObservationMeter
    private var uploadClosed = false
    private var downloadClosed = false
    private var terminal = false

    init(
        client: NWConnection,
        upstream: NWConnection,
        meter: NativeFlowObservationMeter
    ) {
        self.client = client
        self.upstream = upstream
        self.meter = meter
    }

    func halfClose(
        target: NWConnection,
        download: Bool,
        finalPayload: Data? = nil
    ) {
        if let finalPayload, !finalPayload.isEmpty {
            target.send(
                content: finalPayload,
                completion: .contentProcessed { [weak self] error in
                    guard let self else { return }
                    if let error { self.fail(error) }
                    else { self.sendFinalMessage(target: target, download: download) }
                }
            )
        } else {
            sendFinalMessage(target: target, download: download)
        }
    }

    private func sendFinalMessage(target: NWConnection, download: Bool) {
        target.send(
            content: nil,
            contentContext: .finalMessage,
            isComplete: true,
            completion: .contentProcessed { [weak self] error in
                guard let self else { return }
                if let error {
                    self.fail(error)
                    return
                }
                self.lock.lock()
                if download { self.downloadClosed = true }
                else { self.uploadClosed = true }
                let finished = self.uploadClosed && self.downloadClosed && !self.terminal
                if finished { self.terminal = true }
                self.lock.unlock()
                if finished {
                    self.meter.emit(state: .completed)
                    self.client.cancel()
                    self.upstream.cancel()
                }
            }
        )
    }

    func fail(_ error: Error) {
        if Self.isGracefulTransportClosure(error) {
            finishAfterTransportClosure()
            return
        }
        lock.lock()
        guard !terminal else { lock.unlock(); return }
        terminal = true
        lock.unlock()
        meter.fail(
            reason: "Bridge transport failed (\(Self.safeErrorCode(error)))"
        )
        client.cancel()
        upstream.cancel()
    }

    private func finishAfterTransportClosure() {
        lock.lock()
        guard !terminal else { lock.unlock(); return }
        terminal = true
        lock.unlock()
        meter.finishOnCancellation()
        client.cancel()
        upstream.cancel()
    }

    private static func isGracefulTransportClosure(_ error: Error) -> Bool {
        guard let networkError = error as? NWError else { return false }
        guard case let .posix(code) = networkError else { return false }
        return code == .ECANCELED
            || code == .ECONNRESET
            || code == .EPIPE
            || code == .ENOTCONN
    }

    private static func safeErrorCode(_ error: Error) -> String {
        guard let networkError = error as? NWError else {
            return String(describing: type(of: error))
        }
        switch networkError {
        case let .posix(code): return "POSIX:\(code.rawValue)"
        case let .dns(code): return "DNS:\(code)"
        case let .tls(code): return "TLS:\(code)"
        default: return "Network"
        }
    }
}

private final class MClashInboundRoutingState: @unchecked Sendable {
    typealias Route = @Sendable (MClashInboundDestination) -> MClashInboundRoute

    private let lock = NSLock()
    private var route: Route
    private var connector: MClashInboundOutboundConnector

    init(route: @escaping Route, connector: MClashInboundOutboundConnector) {
        self.route = route
        self.connector = connector
    }

    func update(route: @escaping Route, connector: MClashInboundOutboundConnector) {
        lock.lock()
        self.route = route
        self.connector = connector
        lock.unlock()
    }

    func snapshot() -> (route: Route, connector: MClashInboundOutboundConnector) {
        lock.lock()
        defer { lock.unlock() }
        return (route, connector)
    }
}
