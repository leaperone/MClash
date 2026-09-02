import Foundation
@preconcurrency import Network
import MClashNetworkShared

/// QUIC transport adapter for the native Hysteria2 connector. It owns only
/// connection lifecycle and frame writes; routing and relay policy stay above
/// this type.
final class Hysteria2QUICSession: @unchecked Sendable {
    private let connector: NativeHysteria2OutboundConnector
    private let queue: DispatchQueue
    private var connection: NWConnection?
    private var state = Hysteria2Session()
    private var frameDecoder = HTTP3FrameDecoder()
    private var fragmentReassembler = Hysteria2FragmentReassembler()
    private var tcpResponseDecoder = Hysteria2TCPResponseDecoder()

    init(connector: NativeHysteria2OutboundConnector, queue: DispatchQueue = DispatchQueue(label: "one.leaper.mclash.hysteria2-quic")) {
        self.connector = connector
        self.queue = queue
    }

    func start(
        receiveRate: UInt64 = 0,
        padding: String = "",
        completion: @escaping @Sendable (Result<Void, Error>) -> Void
    ) {
        queue.async { [self] in
            guard state.beginConnect() else { return completion(.failure(Hysteria2CodecError.invalidResponse)) }
            let connection = connector.makeConnection()
            self.connection = connection
            connection.stateUpdateHandler = { [weak self] status in
                guard let self else { return }
                self.queue.async {
                    switch status {
                    case .ready:
                        guard self.state.beginAuthentication() else { return }
                        do {
                            let headers = try self.connector.authHeaders(receiveRate: receiveRate, padding: padding)
                            let frame = try QPACKEncoder.encodeLiteralFields(headers)
                            let payload = try HTTP3FrameCodec.encode(HTTP3Frame(type: .headers, payload: frame))
                            connection.send(content: payload, completion: .contentProcessed { error in
                                if let error {
                                    self.state.fail(error.localizedDescription)
                                    completion(.failure(error))
                                } else {
                                    self.readAuthenticationResponse(completion: completion)
                                }
                            })
                        } catch {
                            self.state.fail(error.localizedDescription)
                            completion(.failure(error))
                        }
                    case .failed(let error):
                        self.state.fail(error.localizedDescription)
                        completion(.failure(error))
                    case .cancelled:
                        self.state.fail("QUIC connection cancelled")
                        completion(.failure(Hysteria2CodecError.invalidResponse))
                    default:
                        break
                    }
                }
            }
            connection.start(queue: self.queue)
        }
    }

    private func readAuthenticationResponse(
        completion: @escaping @Sendable (Result<Void, Error>) -> Void
    ) {
        guard let connection else { return }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            self.queue.async {
                if let error {
                    self.state.fail(error.localizedDescription)
                    completion(.failure(error))
                    return
                }
                do {
                    let frames = try self.frameDecoder.append(data ?? Data())
                    for frame in frames where frame.type == .headers {
                        let fields = try QPACKDecoder.decodeLiteralFields(frame.payload)
                        let headers = Dictionary(
                            fields.filter { !$0.0.hasPrefix(":") }.map { ($0.0, $0.1) },
                            uniquingKeysWith: { _, last in last }
                        )
                        let statusText = fields.first { $0.0 == ":status" }?.1 ?? ""
                        let statusCode = Int(statusText.split(separator: " ").first ?? "") ?? 0
                        let response = try Hysteria2Codec.decodeAuthResponse(
                            statusCode: statusCode,
                            headers: headers
                        )
                        guard self.state.handleAuthenticationResponse(
                            statusCode: statusCode,
                            headers: headers
                        ) else {
                            throw Hysteria2CodecError.invalidResponse
                        }
                        _ = response
                        completion(.success(()))
                        return
                    }
                    if !isComplete { self.readAuthenticationResponse(completion: completion) }
                    else { throw Hysteria2CodecError.invalidResponse }
                } catch {
                    self.state.fail(error.localizedDescription)
                    completion(.failure(error))
                }
            }
        }
    }

    func cancel() {
        queue.async { [weak self] in
            guard let self else { return }
            _ = self.state.beginClose()
            self.connection?.cancel()
            _ = self.state.finishClose()
        }
    }

    func openTCPStream(
        to destination: SOCKS5Endpoint,
        padding: Data = Data(),
        completion: @escaping @Sendable (Result<NWConnection, Error>) -> Void
    ) {
        queue.async { [weak self] in
            guard let self, case .ready = self.state.state, let connection = self.connection else {
                completion(.failure(Hysteria2CodecError.invalidResponse))
                return
            }
            do {
                let request = try self.connector.tcpRequest(for: destination, padding: padding)
                connection.send(content: request, completion: .contentProcessed { error in
                    if let error {
                        completion(.failure(error))
                    } else {
                        self.readTCPResponse(connection: connection, completion: completion)
                    }
                })
            } catch {
                completion(.failure(error))
            }
        }
    }

    func readyConnection() -> NWConnection? {
        queue.sync {
            guard case .ready = state.state else { return nil }
            return connection
        }
    }

    func sendUDPMessage(
        _ payload: Data,
        completion: @escaping @Sendable (Error?) -> Void
    ) {
        queue.async { [weak self] in
            guard let self, case .ready(udpEnabled: true) = self.state.state,
                  let connection = self.connection else {
                completion(Hysteria2CodecError.invalidResponse)
                return
            }
            connection.send(
                content: payload,
                contentContext: .defaultMessage,
                isComplete: true,
                completion: .contentProcessed { error in completion(error) }
            )
        }
    }

    func receiveUDPMessage(
        completion: @escaping @Sendable (Result<Hysteria2Codec.UDPMessage, Error>) -> Void
    ) {
        queue.async { [weak self] in
            guard let self, case .ready(udpEnabled: true) = self.state.state,
                  let connection = self.connection else {
                completion(.failure(Hysteria2CodecError.invalidResponse))
                return
            }
            connection.receiveMessage { [weak self] data, _, isComplete, error in
                guard let self else { return }
                self.queue.async {
                    if let error {
                        completion(.failure(error))
                    } else if isComplete, (data ?? Data()).isEmpty {
                        completion(.failure(Hysteria2CodecError.invalidResponse))
                    } else {
                        do {
                            completion(.success(try Hysteria2Codec.decodeUDPMessage(data ?? Data())))
                        } catch {
                            completion(.failure(error))
                        }
                    }
                }
            }
        }
    }

    func receiveReassembledUDPMessage(
        completion: @escaping @Sendable (Result<Hysteria2Codec.UDPMessage, Error>) -> Void
    ) {
        receiveUDPMessage { [weak self] result in
            guard let self else { return }
            switch result {
            case let .failure(error):
                completion(.failure(error))
            case let .success(message):
                self.queue.async { [weak self] in
                    guard let self else { return }
                    if let payload = self.fragmentReassembler.append(message) {
                        completion(.success(Hysteria2Codec.UDPMessage(
                            sessionID: message.sessionID,
                            packetID: message.packetID,
                            fragmentID: 0,
                            fragmentCount: 1,
                            host: message.host,
                            port: message.port,
                            payload: payload
                        )))
                    } else {
                        self.receiveReassembledUDPMessage(completion: completion)
                    }
                }
            }
        }
    }

    private func readTCPResponse(
        connection: NWConnection,
        completion: @escaping @Sendable (Result<NWConnection, Error>) -> Void
    ) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            self.queue.async {
                if let error {
                    completion(.failure(error))
                    return
                }
                do {
                    guard let data, !data.isEmpty else {
                        if isComplete { throw Hysteria2CodecError.invalidResponse }
                        self.readTCPResponse(connection: connection, completion: completion)
                        return
                    }
                    guard let response = try self.tcpResponseDecoder.append(data) else {
                        self.readTCPResponse(connection: connection, completion: completion)
                        return
                    }
                    guard response.accepted else {
                        throw Hysteria2CodecError.serverRejected(response.message)
                    }
                    completion(.success(connection))
                } catch {
                    self.state.fail(error.localizedDescription)
                    completion(.failure(error))
                }
            }
        }
    }
}
