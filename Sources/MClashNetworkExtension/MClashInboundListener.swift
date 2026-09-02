import Foundation
@preconcurrency import Network
import MClashNetworkShared

/// A destination presented by an MClash-owned TCP entrance.
struct MClashInboundDestination: Equatable, Sendable {
    let host: String
    let port: UInt16
}

private extension SOCKS5Endpoint {
    var networkHost: NWEndpoint.Host? {
        if let address = address.ipAddress?.presentation { return NWEndpoint.Host(address) }
        if let domain = address.domain { return NWEndpoint.Host(domain) }
        return nil
    }
    var networkPort: NWEndpoint.Port? { NWEndpoint.Port(rawValue: port) }
}

enum MClashInboundRoute: Equatable, Sendable {
    case direct
    case reject
    case proxy(String)
}

/// Outbound connection boundary for the MClash-owned listener.  The listener
/// never knows whether a proxy connection is backed by Mihomo, Xray, or a
/// future native connector.
protocol MClashInboundOutboundConnector: Sendable {
    func connect(to destination: MClashInboundDestination, route: MClashInboundRoute) -> NWConnection
}

/// Minimal HTTP CONNECT/SOCKS5 TCP server owned by MClash.  It deliberately
/// contains no routing policy: callers supply `route` and a connector. This
/// makes the protocol surface independently testable before AppModel wiring.
final class MClashInboundListener: @unchecked Sendable {
    enum Kind: Sendable { case httpConnect, socks5 }

    let kind: Kind
    private let queue: DispatchQueue
    private let route: @Sendable (MClashInboundDestination) -> MClashInboundRoute
    private let connector: MClashInboundOutboundConnector
    private var listener: NWListener?
    private var connections = [ObjectIdentifier: NWConnection]()
    private(set) var port: UInt16?

    init(kind: Kind, port: UInt16 = 0, queue: DispatchQueue = DispatchQueue(label: "one.leaper.mclash.inbound"), route: @escaping @Sendable (MClashInboundDestination) -> MClashInboundRoute, connector: MClashInboundOutboundConnector) throws {
        self.kind = kind; self.queue = queue; self.route = route; self.connector = connector
        let nwListener = try NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: port)!)
        listener = nwListener
        nwListener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
    }

    func start() {
        queue.async(execute: DispatchWorkItem { [weak self] in
            guard let self, let listener = self.listener else { return }
            listener.stateUpdateHandler = { [weak self] state in
                if case .ready = state { self?.port = listener.port?.rawValue }
            }
            listener.start(queue: queue)
        })
    }

    func stop() {
        queue.async(execute: DispatchWorkItem { [weak self] in
            guard let self else { return }
            listener?.cancel(); listener = nil
            connections.values.forEach { $0.cancel() }; connections.removeAll(); port = nil
        })
    }

    private func accept(_ connection: NWConnection) {
        queue.async { [weak self, connection] in
            guard let self else { connection.cancel(); return }
            connections[ObjectIdentifier(connection)] = connection
            connection.stateUpdateHandler = { [weak self, weak connection] state in
                guard case .failed = state, let self, let connection else { return }
                self.queue.async { self.connections.removeValue(forKey: ObjectIdentifier(connection)) }
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
        let decision = route(destination)
        guard decision != .reject else {
            let rejection = response.starts(with: Data("HTTP/".utf8)) ? HTTPProxyCodec.encodeFailureResponse(status: 403, reason: "Forbidden") : Self.socksReply(.connectionNotAllowed)
            client.send(content: rejection, completion: .contentProcessed { _ in client.cancel() }); return
        }
        let upstream: NWConnection
        switch decision { case .direct: upstream = NWConnection(host: NWEndpoint.Host(destination.host), port: NWEndpoint.Port(rawValue: destination.port)!, using: .tcp); case .proxy: upstream = connector.connect(to: destination, route: decision); case .reject: return }
        client.send(content: response, completion: .contentProcessed { [weak self] error in
            guard let self, error == nil else { client.cancel(); return }
            upstream.stateUpdateHandler = { state in if case .ready = state { self.bridge(client, upstream) } else if case .failed = state { client.cancel() } }
            upstream.start(queue: self.queue)
        })
    }

    private func bridge(_ a: NWConnection, _ b: NWConnection) {
        pump(from: a, to: b); pump(from: b, to: a)
    }
    private func pump(from source: NWConnection, to target: NWConnection) {
        source.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, complete, error in
            guard let self, error == nil, let data, !data.isEmpty else { if complete { target.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in target.cancel() }) }; return }
            target.send(content: data, completion: .contentProcessed { _ in self.pump(from: source, to: target) })
        }
    }

    private static func socksReply(_ code: SOCKS5ReplyCode) -> Data { Data([5, code.rawValue, 0, 1, 0, 0, 0, 0, 0, 0]) }
}
