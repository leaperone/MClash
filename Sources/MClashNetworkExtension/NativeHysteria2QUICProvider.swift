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
        authStream?.cancel()
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
        }.start()
        try await waitUntilReady(connection)
        self.connection = connection
        return connection
    }

    private func waitUntilReady(_ connection: NetworkConnection<QUIC>) async throws {
        if connection.state == .ready { return }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                _ = connection.onStateUpdate { connection, state in
                    switch state {
                    case .ready:
                        continuation.resume()
                    case .failed(let error):
                        continuation.resume(throwing: error)
                    case .cancelled:
                        continuation.resume(throwing: Hysteria2TransportError.closed)
                    default:
                        break
                    }
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
        return try await stream.receive(atLeast: 1, atMost: 1_048_576).content
    }

    func halfClose() async {
        try? await stream.send(Data(), endOfStream: true)
    }

    func close() async {
        stream.streamApplicationErrorCode = 0x100
        try? await stream.send(Data(), endOfStream: true)
    }
}
