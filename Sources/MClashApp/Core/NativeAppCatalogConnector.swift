import CryptoKit
import Foundation
@preconcurrency import Network
import MClashNetworkShared

/// App-process outbound connector for the socket entrances.  It intentionally
/// implements only transports whose wire handshake is available in the app
/// target; unsupported node protocols fail closed during the route decision.
struct NativeAppCatalogConnector: MClashInboundOutboundConnector {
    let catalog: OutboundNodeTargetCatalog?
    private let shadowsocksState = NativeAppShadowsocksState()

    static func supports(_ target: OutboundNodeTarget) -> Bool {
        switch target.protocolName {
        case "http", "socks5":
            true
        case "ss", "shadowsocks":
            Self.shadowsocksSupported(target)
        case "vless":
            target.parameters["uuid"] != nil
                && {
                    let network = target.parameters["network"]?.lowercased() ?? "tcp"
                    return network == "tcp"
                        || network == "ws" && target.vlessWebSocketOptions != nil
                }()
        case "trojan":
            (target.parameters["network"]?.lowercased() ?? "tcp") == "tcp"
                && (target.parameters["password"] ?? target.parameters["passwd"]) != nil
        default:
            false
        }
    }

    private static func shadowsocksSupported(_ target: OutboundNodeTarget) -> Bool {
        guard let password = target.parameters["password"] ?? target.parameters["passwd"], !password.isEmpty else { return false }
        let plugin = target.parameters["plugin"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let uot = target.parameters["uot"]?.lowercased() == "true" || target.parameters["udp"]?.lowercased() == "true"
        return plugin.isEmpty && !uot
    }

    func makeBridgeCodec(
        to destination: MClashInboundDestination,
        route: MClashInboundRoute
    ) throws -> (any MClashInboundBridgeCodec)? {
        guard case let .proxy(key) = route,
              let target = target(for: key),
              (target.protocolName == "vless" || target.protocolName == "ss" || target.protocolName == "shadowsocks") else { return nil }
        if target.protocolName == "ss" || target.protocolName == "shadowsocks" {
            guard let codec = shadowsocksState.take(for: key) else { throw NativeAppCatalogConnectorError.unsupportedProtocol("shadowsocks state") }
            return codec
        }
        let endpoint = try SOCKS5Endpoint(
            address: SOCKS5Address(domain: destination.host),
            port: destination.port
        )
        if target.parameters["network"]?.lowercased() == "ws" {
            return try NativeAppVLESSWebSocketBridge(
                target: target,
                destination: endpoint
            )
        }
        return NativeAppVLESSPlainBridge()
    }

    func connect(to _: MClashInboundDestination, route: MClashInboundRoute) -> NWConnection {
        guard case let .proxy(key) = route,
              let target = target(for: key),
              Self.supports(target) else {
            return NWConnection(host: NWEndpoint.Host("127.0.0.1"), port: 1, using: .tcp)
        }
        let usesTLS = target.protocolName == "trojan"
            || target.protocolName == "vless"
                && ["true", "1", "yes", "on"].contains(
                    target.parameters["tls"]?.lowercased() ?? "false"
                )
        let parameters: NWParameters
        if usesTLS {
            let tls = NWProtocolTLS.Options()
            let serverName = target.parameters["sni"]
                ?? target.parameters["servername"]
                ?? target.host
            serverName.withCString {
                sec_protocol_options_set_tls_server_name(
                    tls.securityProtocolOptions,
                    $0
                )
            }
            parameters = NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
        } else {
            parameters = .tcp
        }
        return NWConnection(
            host: NWEndpoint.Host(target.connectionHost),
            port: NWEndpoint.Port(rawValue: target.port)!,
            using: parameters
        )
    }

    func establish(
        _ connection: NWConnection,
        to destination: MClashInboundDestination,
        route: MClashInboundRoute,
        completion: @escaping @Sendable (Error?) -> Void
    ) {
        guard case let .proxy(key) = route,
              let target = target(for: key) else {
            completion(nil); return
        }
        do {
            if target.protocolName == "http" {
                let request = try HTTPProxyCodec.encodeConnectRequest(
                    host: destination.host,
                    port: destination.port,
                    username: target.parameters["username"],
                    password: target.parameters["password"]
                )
                connection.send(content: request, completion: .contentProcessed { error in
                    if let error { completion(error); return }
                    self.readHTTPResponse(connection, buffer: Data(), completion: completion)
                })
            } else if target.protocolName == "socks5" {
                let username = target.parameters["username"] ?? target.parameters["user"]
                let password = target.parameters["password"] ?? target.parameters["pass"]
                let methods: [SOCKS5AuthenticationMethod] = username != nil && password != nil
                    ? [.usernamePassword] : [.noAuthenticationRequired]
                let greeting = try SOCKS5Codec.encodeGreeting(methods: methods)
                connection.send(content: greeting, completion: .contentProcessed { error in
                    if let error { completion(error); return }
                    self.readSOCKSMethod(connection, destination: destination, target: target, completion: completion)
                })
            } else if target.protocolName == "ss" || target.protocolName == "shadowsocks" {
                guard Self.shadowsocksSupported(target) else { throw NativeAppCatalogConnectorError.unsupportedProtocol("shadowsocks features") }
                let codec = try NativeAppShadowsocksCodec(target: target, destination: destination, routeKey: key)
                shadowsocksState.store(codec, for: connection)
                connection.send(content: try codec.destinationPreamble(), completion: .contentProcessed(completion))
            } else if target.protocolName == "vless" {
                let endpoint = try SOCKS5Endpoint(
                    address: SOCKS5Address(domain: destination.host),
                    port: destination.port
                )
                if target.parameters["network"]?.lowercased() == "ws" {
                    let upgrade = try webSocketUpgrade(target: target)
                    connection.send(
                        content: upgrade.request,
                        completion: .contentProcessed { error in
                            if let error { completion(error); return }
                            self.readWebSocketResponse(
                                connection,
                                target: target,
                                destination: endpoint,
                                expectedAccept: upgrade.expectedAccept,
                                buffer: Data(),
                                completion: completion
                            )
                        }
                    )
                } else {
                    guard let uuid = target.parameters["uuid"] else {
                        throw VLESSCodecError.invalidUUID
                    }
                    let request = try VLESSCodec.encodeTCPRequest(
                        uuid: uuid,
                        host: destination.host,
                        port: destination.port
                    )
                    connection.send(
                        content: request,
                        completion: .contentProcessed(completion)
                    )
                }
            } else if target.protocolName == "trojan" {
                guard let password = target.parameters["password"]
                    ?? target.parameters["passwd"] else {
                    throw TrojanCodecError.invalidPassword
                }
                let request = try TrojanCodec.encodeTCPRequest(
                    password: password,
                    host: destination.host,
                    port: destination.port
                )
                connection.send(
                    content: request,
                    completion: .contentProcessed(completion)
                )
            } else {
                completion(NativeAppCatalogConnectorError.unsupportedProtocol(target.protocolName))
            }
        } catch { completion(error) }
    }

    /// Payload-aware establishment used by the app-owned listener. This
    /// overload keeps the legacy Error-only API intact for callers while
    /// preserving bytes coalesced after an HTTP CONNECT response.
    func establishWithInitialPayload(
        _ connection: NWConnection,
        to destination: MClashInboundDestination,
        route: MClashInboundRoute,
        completion: @escaping @Sendable (Error?, Data) -> Void
    ) {
        guard case let .proxy(key) = route, let target = target(for: key), target.protocolName == "http" else {
            if case let .proxy(key) = route, let target = target(for: key), target.protocolName == "socks5" {
                establishSOCKSWithInitialPayload(connection, destination: destination, target: target, completion: completion)
                return
            }
            establish(connection, to: destination, route: route) { error in completion(error, Data()) }
            return
        }
        do {
            let request = try HTTPProxyCodec.encodeConnectRequest(
                host: destination.host, port: destination.port,
                username: target.parameters["username"], password: target.parameters["password"]
            )
            connection.send(content: request, completion: .contentProcessed { error in
                if let error { completion(error, Data()); return }
                self.readHTTPResponseWithPayload(connection, buffer: Data(), completion: completion)
            })
        } catch { completion(error, Data()) }
    }

    private func target(for key: String) -> OutboundNodeTarget? {
        catalog?.entries.first { $0.route.stableSortKey == key }?.target
    }


    private func establishSOCKSWithInitialPayload(_ connection: NWConnection, destination: MClashInboundDestination, target: OutboundNodeTarget, completion: @escaping @Sendable (Error?, Data) -> Void) {
        let user = target.parameters["username"] ?? target.parameters["user"]
        let pass = target.parameters["password"] ?? target.parameters["pass"]
        do {
            let methods: [SOCKS5AuthenticationMethod] = user != nil && pass != nil ? [.usernamePassword] : [.noAuthenticationRequired]
            connection.send(content: try SOCKS5Codec.encodeGreeting(methods: methods), completion: .contentProcessed { [self] error in
                if let error { completion(error, Data()); return }
                readSOCKSMethodWithInitialPayload(connection, destination: destination, target: target, completion: completion)
            })
        } catch { completion(error, Data()) }
    }

    private func readSOCKSMethodWithInitialPayload(_ connection: NWConnection, destination: MClashInboundDestination, target: OutboundNodeTarget, decoder: SOCKS5MethodSelectionDecoder = .init(), completion: @escaping @Sendable (Error?, Data) -> Void) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 2) { [self] data, _, complete, error in
            do {
                if let error { throw error }; var decoder = decoder
                guard let data else { throw NativeAppCatalogConnectorError.truncatedResponse }
                guard let selection = try decoder.append(data) else { if complete { throw NativeAppCatalogConnectorError.truncatedResponse }; readSOCKSMethodWithInitialPayload(connection, destination: destination, target: target, decoder: decoder, completion: completion); return }
                if selection.method == .usernamePassword {
                    guard let user = target.parameters["username"] ?? target.parameters["user"], let pass = target.parameters["password"] ?? target.parameters["pass"] else { throw NativeAppCatalogConnectorError.missingCredentials }
                    let auth = try SOCKS5Codec.encodeUsernamePasswordRequest(credentials: SOCKS5UsernamePasswordCredentials(username: user, password: pass))
                    connection.send(content: auth, completion: .contentProcessed { [self] error in
                        if let error { completion(error, Data()); return }; readSOCKSAuthWithInitialPayload(connection, destination: destination, completion: completion)
                    })
                } else { try sendSOCKSCommandWithInitialPayload(connection, destination: destination, completion: completion) }
            } catch { completion(error, Data()); connection.cancel() }
        }
    }

    private func readSOCKSAuthWithInitialPayload(_ connection: NWConnection, destination: MClashInboundDestination, decoder: SOCKS5UsernamePasswordResponseDecoder = .init(), completion: @escaping @Sendable (Error?, Data) -> Void) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 2) { [self] data, _, complete, error in
            do {
                if let error { throw error }; var decoder = decoder; guard let data else { throw NativeAppCatalogConnectorError.truncatedResponse }
                guard let response = try decoder.append(data) else { if complete { throw NativeAppCatalogConnectorError.truncatedResponse }; readSOCKSAuthWithInitialPayload(connection, destination: destination, decoder: decoder, completion: completion); return }
                try response.requireSuccess(); try sendSOCKSCommandWithInitialPayload(connection, destination: destination, completion: completion)
            } catch { completion(error, Data()); connection.cancel() }
        }
    }

    private func sendSOCKSCommandWithInitialPayload(_ connection: NWConnection, destination: MClashInboundDestination, completion: @escaping @Sendable (Error?, Data) -> Void) throws {
        let endpoint = try SOCKS5Endpoint(address: SOCKS5Address(domain: destination.host), port: destination.port)
        let request = try SOCKS5Codec.encodeCommandRequest(SOCKS5CommandRequest(command: .connect, endpoint: endpoint))
        connection.send(content: request, completion: .contentProcessed { [self] error in
            if let error { completion(error, Data()); return }
            readSOCKSCommandWithInitialPayload(connection, completion: completion)
        })
    }

    private func readSOCKSCommandWithInitialPayload(_ connection: NWConnection, decoder: SOCKS5CommandReplyDecoder = .init(), completion: @escaping @Sendable (Error?, Data) -> Void) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: SOCKS5Limits.maximumStreamInputBytes) { [self] data, _, complete, error in
            do {
                if let error { throw error }; var decoder = decoder; guard let data else { throw NativeAppCatalogConnectorError.truncatedResponse }
                guard let reply = try decoder.append(data) else { if complete { throw NativeAppCatalogConnectorError.truncatedResponse }; readSOCKSCommandWithInitialPayload(connection, decoder: decoder, completion: completion); return }
                try reply.requireSuccess(); completion(nil, decoder.remainingData)
            } catch { completion(error, Data()); connection.cancel() }
        }
    }

    private func webSocketUpgrade(
        target: OutboundNodeTarget
    ) throws -> (request: Data, expectedAccept: String) {
        guard target.parameters["uuid"] != nil,
              let options = target.vlessWebSocketOptions else {
            throw NativeAppCatalogConnectorError.unsupportedProtocol("vless websocket")
        }
        let key = Data((0..<16).map { _ in UInt8.random(in: 0...255) })
            .base64EncodedString()
        let expectedAccept = Data(Insecure.SHA1.hash(
            data: Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8)
        )).base64EncodedString()
        let configuredHost = options.headers.first {
            $0.key.caseInsensitiveCompare("Host") == .orderedSame
        }?.value
        var headers: [(String, String)] = [
            ("Host", configuredHost ?? target.parameters["ws-host"] ?? target.host),
            ("Upgrade", "websocket"),
            ("Connection", "Upgrade"),
            ("Sec-WebSocket-Version", "13"),
            ("Sec-WebSocket-Key", key)
        ]
        let reserved = Set(headers.map { $0.0.lowercased() })
        headers.append(contentsOf: options.headers.compactMap { name, value in
            reserved.contains(name.lowercased()) ? nil : (name, value)
        })
        var request = "GET \(options.path) HTTP/1.1\r\n"
        request += headers.map { "\($0.0): \($0.1)\r\n" }.joined()
        request += "\r\n"
        return (Data(request.utf8), expectedAccept)
    }

    private func readWebSocketResponse(
        _ connection: NWConnection,
        target: OutboundNodeTarget,
        destination: SOCKS5Endpoint,
        expectedAccept: String,
        buffer: Data,
        completion: @escaping @Sendable (Error?) -> Void
    ) {
        connection.receive(
            minimumIncompleteLength: 1,
            maximumLength: max(1, HTTPProxyCodec.maximumHeaderBytes - buffer.count)
        ) { [self] data, _, complete, error in
            if let error { completion(error); return }
            var next = buffer
            if let data { next.append(data) }
            guard next.count <= HTTPProxyCodec.maximumHeaderBytes else {
                completion(NativeAppCatalogConnectorError.truncatedResponse)
                connection.cancel()
                return
            }
            if let end = next.range(of: Data("\r\n\r\n".utf8)) {
                do {
                    try validateWebSocketResponse(
                        Data(next[..<end.upperBound]),
                        expectedAccept: expectedAccept
                    )
                    let frame = try VLESSWebSocketTunnelCodec(
                        target: target,
                        destination: destination
                    ).encodeDestination()
                    connection.send(
                        content: frame,
                        completion: .contentProcessed(completion)
                    )
                } catch {
                    completion(error)
                    connection.cancel()
                }
            } else if complete {
                completion(NativeAppCatalogConnectorError.truncatedResponse)
                connection.cancel()
            } else {
                readWebSocketResponse(
                    connection,
                    target: target,
                    destination: destination,
                    expectedAccept: expectedAccept,
                    buffer: next,
                    completion: completion
                )
            }
        }
    }

    private func validateWebSocketResponse(
        _ response: Data,
        expectedAccept: String
    ) throws {
        guard let text = String(data: response, encoding: .utf8) else {
            throw NativeAppCatalogConnectorError.invalidWebSocketUpgrade
        }
        let lines = text.components(separatedBy: "\r\n")
        guard lines.first?.hasPrefix("HTTP/1.1 101 ") == true else {
            throw NativeAppCatalogConnectorError.invalidWebSocketUpgrade
        }
        var values: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            values[String(line[..<colon]).lowercased()] = String(
                line[line.index(after: colon)...]
            ).trimmingCharacters(in: .whitespaces)
        }
        guard values["upgrade"]?.lowercased() == "websocket",
              values["connection"]?.lowercased().contains("upgrade") == true,
              values["sec-websocket-accept"] == expectedAccept else {
            throw NativeAppCatalogConnectorError.invalidWebSocketUpgrade
        }
    }

    private func readHTTPResponse(_ connection: NWConnection, buffer: Data, completion: @escaping @Sendable (Error?) -> Void) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: HTTPProxyCodec.maximumHeaderBytes) { [self] data, _, complete, error in
            var next = buffer; if let data { next.append(data) }
            if let error { completion(error); return }
            do {
                var parser = NativeHTTPConnectResponseParser(buffer: next)
                if let result = try parser.append(Data()) {
                    // The parser deliberately separates the header from any
                    // bytes coalesced with it. The trailing bytes are retained
                    // in the parser result instead of being fed to the HTTP
                    // header decoder (or silently interpreted as headers).
                    _ = result.trailing
                    completion(nil)
                } else if complete {
                    completion(NativeAppCatalogConnectorError.truncatedResponse)
                    connection.cancel()
                } else {
                    readHTTPResponse(connection, buffer: next, completion: completion)
                }
            } catch {
                completion(error); connection.cancel()
            }
        }
    }

    private func readHTTPResponseWithPayload(_ connection: NWConnection, buffer: Data, completion: @escaping @Sendable (Error?, Data) -> Void) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: HTTPProxyCodec.maximumHeaderBytes) { [self] data, _, complete, error in
            var next = buffer; if let data { next.append(data) }
            if let error { completion(error, Data()); return }
            do {
                var parser = NativeHTTPConnectResponseParser(buffer: next)
                if let result = try parser.append(Data()) {
                    completion(nil, result.trailing)
                } else if complete {
                    completion(NativeAppCatalogConnectorError.truncatedResponse, Data()); connection.cancel()
                } else {
                    self.readHTTPResponseWithPayload(connection, buffer: next, completion: completion)
                }
            } catch { completion(error, Data()); connection.cancel() }
        }
    }

    private func readSOCKSMethod(_ connection: NWConnection, destination: MClashInboundDestination, target: OutboundNodeTarget, decoder: SOCKS5MethodSelectionDecoder = .init(), completion: @escaping @Sendable (Error?) -> Void) {
        connection.receive(minimumIncompleteLength: 2, maximumLength: 2) { [self] data, _, complete, error in
            do {
                if let error { throw error }
                var decoder = decoder
                guard let data else { throw NativeAppCatalogConnectorError.truncatedResponse }
                guard let selection = try decoder.append(data) else {
                    if complete { throw NativeAppCatalogConnectorError.truncatedResponse }
                    self.readSOCKSMethod(connection, destination: destination, target: target, decoder: decoder, completion: completion)
                    return
                }
                let method = selection.method
                if method == .usernamePassword {
                    guard let username = target.parameters["username"] ?? target.parameters["user"], let password = target.parameters["password"] ?? target.parameters["pass"] else { throw NativeAppCatalogConnectorError.missingCredentials }
                    let auth = try SOCKS5Codec.encodeUsernamePasswordRequest(credentials: SOCKS5UsernamePasswordCredentials(username: username, password: password))
                    connection.send(content: auth, completion: .contentProcessed { error in
                        if let error { completion(error); return }
                        self.readSOCKSAuthentication(connection, destination: destination, completion: completion)
                    })
                } else {
                    try sendSOCKSCommand(connection, destination: destination, completion: completion)
                }
            } catch { completion(error); connection.cancel() }
        }
    }

    private func sendSOCKSCommand(_ connection: NWConnection, destination: MClashInboundDestination, completion: @escaping @Sendable (Error?) -> Void) throws {
        let endpoint = try SOCKS5Endpoint(address: SOCKS5Address(domain: destination.host), port: destination.port)
        connection.send(content: try SOCKS5Codec.encodeCommandRequest(SOCKS5CommandRequest(command: .connect, endpoint: endpoint)), completion: .contentProcessed { error in
            if let error { completion(error); return }
            self.readSOCKSCommandResponse(connection, completion: completion)
        })
    }

    private func readSOCKSAuthentication(_ connection: NWConnection, destination: MClashInboundDestination, decoder: SOCKS5UsernamePasswordResponseDecoder = .init(), completion: @escaping @Sendable (Error?) -> Void) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 2) { [self] data, _, complete, error in
            do {
                if let error { throw error }; var decoder = decoder
                guard let data else { throw NativeAppCatalogConnectorError.truncatedResponse }
                guard let response = try decoder.append(data) else {
                    if complete { throw NativeAppCatalogConnectorError.truncatedResponse }
                    self.readSOCKSAuthentication(connection, destination: destination, decoder: decoder, completion: completion); return
                }
                try response.requireSuccess(); try self.sendSOCKSCommand(connection, destination: destination, completion: completion)
            } catch { completion(error); connection.cancel() }
        }
    }

    private func readSOCKSCommandResponse(_ connection: NWConnection, decoder: SOCKS5CommandReplyDecoder = .init(), completion: @escaping @Sendable (Error?) -> Void) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: SOCKS5Limits.maximumStreamInputBytes) { [self] data, _, complete, error in
            do {
                if let error { throw error }; var decoder = decoder
                guard let data else { throw NativeAppCatalogConnectorError.truncatedResponse }
                guard let reply = try decoder.append(data) else {
                    if complete { throw NativeAppCatalogConnectorError.truncatedResponse }
                    self.readSOCKSCommandResponse(connection, decoder: decoder, completion: completion); return
                }
                try reply.requireSuccess()
                // decoder.remainingData is intentionally preserved by the
                // incremental parser for the listener's subsequent bridge.
                completion(nil)
            } catch { completion(error); connection.cancel() }
        }
    }
}

/// Incremental HTTP CONNECT response parser. It validates only the bounded
/// header and returns bytes received after CRLFCRLF separately.
struct NativeHTTPConnectResponseParser: Sendable {
    private var buffer: Data
    init(buffer: Data = Data()) { self.buffer = buffer }
    mutating func append(_ data: Data) throws -> (status: Int, trailing: Data)? {
        guard buffer.count + data.count <= SOCKS5Limits.maximumStreamInputBytes else {
            throw NativeAppCatalogConnectorError.truncatedResponse
        }
        buffer.append(data)
        guard let end = buffer.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let headerEnd = end.upperBound
        guard headerEnd <= HTTPProxyCodec.maximumHeaderBytes else {
            throw NativeAppCatalogConnectorError.truncatedResponse
        }
        return (try HTTPProxyCodec.decodeConnectResponse(Data(buffer[..<headerEnd])), Data(buffer[headerEnd...]))
    }
}

private final class NativeAppVLESSPlainBridge: MClashInboundBridgeCodec, @unchecked Sendable {
    private var responseDecoder = VLESSResponseDecoder()
    func encode(_ payload: Data) throws -> Data { payload }
    func decode(_ input: Data) throws -> [Data] { try responseDecoder.append(input) }
}

private final class NativeAppVLESSWebSocketBridge: MClashInboundBridgeCodec, @unchecked Sendable {
    private let codec: VLESSWebSocketTunnelCodec
    init(target: OutboundNodeTarget, destination: SOCKS5Endpoint) throws {
        codec = try VLESSWebSocketTunnelCodec(target: target, destination: destination)
    }
    func encode(_ payload: Data) throws -> Data { try codec.encode(payload) }
    func decode(_ input: Data) throws -> [Data] { try codec.decode(input) }
}

enum NativeAppCatalogConnectorError: Error, Equatable, Sendable {
    case unsupportedProtocol(String)
    case truncatedResponse
    case missingCredentials
    case invalidWebSocketUpgrade
}

private final class NativeAppShadowsocksState: @unchecked Sendable {
    private let lock = NSLock()
    private var codecs: [String: NativeAppShadowsocksCodec] = [:]
    func store(_ codec: NativeAppShadowsocksCodec, for connection: NWConnection) {
        lock.lock(); defer { lock.unlock() }; codecs[key(connection)] = codec
    }
    func take(for routeKey: String) -> NativeAppShadowsocksCodec? {
        lock.lock(); defer { lock.unlock() }
        // Establishment and bridge construction are serialized by the
        // listener; route-key fallback keeps this state usable across the
        // value-type connector copies used by the runtime.
        if let match = codecs.first(where: { $0.value.routeKey == routeKey }) { codecs.removeValue(forKey: match.key); return match.value }
        return nil
    }
    private func key(_ connection: NWConnection) -> String { String(ObjectIdentifier(connection).hashValue) }
}

final class NativeAppShadowsocksCodec: MClashInboundBridgeCodec, @unchecked Sendable {
    private var encoder: ShadowsocksAEADStreamEncoder
    private var decoder: ShadowsocksAEADStreamDecoder
    let routeKey: String
    private let destination: Data
    init(target: OutboundNodeTarget, destination: MClashInboundDestination, routeKey: String) throws {
        let method = target.parameters["method"] ?? target.parameters["cipher"] ?? "aes-256-gcm"
        let password = target.parameters["password"] ?? target.parameters["passwd"] ?? ""
        encoder = try ShadowsocksAEADStreamEncoder(methodName: method, password: password)
        decoder = try ShadowsocksAEADStreamDecoder(methodName: method, password: password)
        self.routeKey = routeKey
        self.destination = try ShadowsocksAEADStreamEncoder.encodeDestination(host: destination.host, port: destination.port)
    }
    func destinationPreamble() throws -> Data { try encoder.encode(destination) }
    func encode(_ payload: Data) throws -> Data { try encoder.encode(payload) }
    func decode(_ input: Data) throws -> [Data] { try decoder.append(input) }
}
