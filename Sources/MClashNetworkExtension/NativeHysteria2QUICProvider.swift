import Foundation
import Network
import MClashNetworkShared

/// macOS 26 transport backed by Network's typed QUIC multiplex API.  This is
/// intentionally separate from the macOS 14 NWConnection adapter: the latter
/// cannot create child QUIC streams and therefore cannot truthfully implement
/// Hysteria2's one-stream-per-TCP-request contract.
@available(macOS 26.0, *)
actor NativeHysteria2QUICProvider: Hysteria2TransportProvider {
    private let connector: NativeHysteria2OutboundConnector
    private var connection: NetworkConnection<QUIC>?
    private var authStream: QUIC.Stream<QUICStream>?

    init(connector: NativeHysteria2OutboundConnector) {
        self.connector = connector
    }

    /// Explicit preparation hook used by the opt-in interoperability probe to
    /// distinguish QUIC/TLS reachability from HTTP/3 authentication framing.
    /// Production callers continue to use the lazy protocol interface.
    func prepareConnection() async throws {
        _ = try await connect()
    }

    func authenticate() async throws -> Bool {
        let connection = try await connect()
        let stream = try await connection.openStream()
        authStream = stream
        do {
            let headers = try connector.authHeaders()
            let fields = try QPACKEncoder.encodeLiteralFields(headers)
            try await stream.send(HTTP3FrameCodec.encode(HTTP3Frame(type: .headers, payload: fields)))
            var decoder = HTTP3FrameDecoder()
            while true {
                let message = try await stream.receive(atLeast: 1, atMost: 64 * 1024)
                for frame in try decoder.append(message.content) where frame.type == .headers {
                    let fields = try QPACKDecoder.decodeLiteralFields(frame.payload)
                    let status = Int(fields.first { $0.0 == ":status" }?.1.split(separator: " ").first ?? "") ?? 0
                    let headers = Dictionary(fields.filter { !$0.0.hasPrefix(":") }, uniquingKeysWith: { _, last in last })
                    _ = try Hysteria2Codec.decodeAuthResponse(statusCode: status, headers: headers)
                    return true
                }
                if message.metadata.endOfStream {
                    throw Hysteria2CodecError.invalidResponse
                }
            }
        } catch {
            stream.streamApplicationErrorCode = 0x100
            try? await stream.send(Data(), endOfStream: true)
            authStream = nil
            throw error
        }
    }

    func openBidirectionalStream() async throws -> any Hysteria2StreamTransport {
        let connection = try await connect()
        return NativeHysteria2QUICStream(stream: try await connection.openStream())
    }

    func sendDatagram(_ data: Data) async throws {
        try await connect().datagrams.send(data)
    }

    func receiveDatagram() async throws -> Data? {
        try await connect().datagrams.receive().content
    }

    func close() async {
        if let authStream {
            authStream.streamApplicationErrorCode = 0x100
            try? await authStream.send(Data(), endOfStream: true)
        }
        authStream = nil
        connection?.applicationError = Network.NWProtocolQUIC.ApplicationError(code: 0x100, reason: "closed")
        connection = nil
    }

    private func connect() async throws -> NetworkConnection<QUIC> {
        if let connection { return connection }
        let endpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(connector.target.connectionHost),
            port: NWEndpoint.Port(rawValue: connector.target.port)!
        )
        let connection = NetworkConnection(to: endpoint) {
            QUIC(alpn: ["h3"])
        }
        try await waitUntilReady(connection)
        self.connection = connection
        return connection
    }

    private func waitUntilReady(_ connection: NetworkConnection<QUIC>) async throws {
        let completionGate = NativeHysteria2ContinuationGate()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                _ = connection.onStateUpdate { connection, state in
                    switch state {
                    case .ready:
                        completionGate.resume { continuation.resume() }
                    case .failed(let error):
                        completionGate.resume {
                            continuation.resume(throwing: error)
                        }
                    case .cancelled:
                        completionGate.resume {
                            continuation.resume(
                                throwing: Hysteria2TransportError.closed
                            )
                        }
                    default:
                        break
                    }
                }
                // Install the handler before starting.  Starting first can
                // transition through ready before the callback is attached,
                // leaving a continuation suspended forever.
                _ = connection.start()
                switch connection.state {
                case .ready:
                    completionGate.resume { continuation.resume() }
                case .failed(let error):
                    completionGate.resume { continuation.resume(throwing: error) }
                case .cancelled:
                    completionGate.resume { continuation.resume(throwing: Hysteria2TransportError.closed) }
                default:
                    break
                }
            }
        } onCancel: {
            connection.applicationError = Network.NWProtocolQUIC.ApplicationError(code: 0x100, reason: "cancelled")
        }
    }
}

@available(macOS 26.0, *)
private final class NativeHysteria2QUICStream: Hysteria2StreamTransport, @unchecked Sendable {
    private let stream: QUIC.Stream<QUICStream>

    init(stream: QUIC.Stream<QUICStream>) {
        self.stream = stream
    }

    func send(_ data: Data) async throws {
        try Task.checkCancellation()
        try await stream.send(data)
    }

    func receive() async throws -> Data? {
        try Task.checkCancellation()
        let message = try await stream.receive(atLeast: 1, atMost: 1_048_576)
        if message.content.isEmpty, message.metadata.endOfStream { return nil }
        return message.content
    }

    func halfClose() async {
        try? await stream.send(Data(), endOfStream: true)
    }

    func close() async {
        stream.streamApplicationErrorCode = 0x100
        try? await stream.send(Data(), endOfStream: true)
    }
}

/// Internal so timing tests can exercise the exactly-once continuation guard
/// without opening a network connection.
final class NativeHysteria2ContinuationGate: @unchecked Sendable {
    private let lock = NSLock()
    private var completed = false

    func resume(_ action: () -> Void) {
        lock.lock()
        guard !completed else {
            lock.unlock()
            return
        }
        completed = true
        lock.unlock()
        action()
    }
}
