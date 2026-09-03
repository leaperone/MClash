import CryptoKit
import Foundation
@preconcurrency import Network
import MClashNetworkShared
import Testing
@testable import MClashNetworkExtension

/// These tests use only 127.0.0.1.  They deliberately exercise the socket
/// boundary (rather than just comparing encoded Data) while keeping the
/// server deterministic and independent of a subscription or the installed
/// Mihomo process.
@Suite("Native connector loopback fixtures")
struct NativeConnectorLoopbackFixtureTests {
    @Test("HTTP CONNECT gates the stream on a 2xx response and round-trips payload")
    func httpConnectLoopback() throws {
        let server = try LoopbackTCPFixture()
        defer { server.stop() }
        let target = try OutboundNodeTarget(protocolName: "http", host: "127.0.0.1", port: server.port)
        let destination = SOCKS5Endpoint(address: try SOCKS5Address(domain: "example.com"), port: 443)
        let connector = NativeHTTPConnectOutboundConnector(target: target)
        let client = connector.makeConnection()
        try LoopbackTCPFixture.start(client)
        try LoopbackTCPFixture.send(
            client,
            data: try connector.handshake(for: destination)
        )

        let request = try server.read(until: Data("\r\n\r\n".utf8))
        #expect(try HTTPProxyCodec.decodeConnectRequest(request).host == "example.com")
        try server.send(Data("HTTP/1.1 200 Connection Established\r\n\r\n".utf8))
        let response = try LoopbackTCPFixture.read(client, until: Data("\r\n\r\n".utf8))
        #expect(try connector.validate(response: response) == 200)

        try LoopbackTCPFixture.send(client, data: Data("ping".utf8))
        #expect(try server.read(atLeast: 4).suffix(4) == Data("ping".utf8))
        try server.send(Data("pong".utf8))
        #expect(try LoopbackTCPFixture.read(client, atLeast: 4).suffix(4) == Data("pong".utf8))
        client.cancel()
        _ = destination // Keep the destination visible in this fixture's contract.
    }

    @Test("HTTP CONNECT rejects a non-2xx response before payload exchange")
    func httpConnectFailureLoopback() throws {
        let server = try LoopbackTCPFixture()
        defer { server.stop() }
        let target = try OutboundNodeTarget(protocolName: "http", host: "127.0.0.1", port: server.port)
        let destination = SOCKS5Endpoint(address: try SOCKS5Address(domain: "blocked.example"), port: 443)
        let connector = NativeHTTPConnectOutboundConnector(target: target)
        let client = connector.makeConnection()
        try LoopbackTCPFixture.start(client)
        try LoopbackTCPFixture.send(
            client,
            data: try connector.handshake(for: destination)
        )
        _ = try server.read(until: Data("\r\n\r\n".utf8))
        try server.send(Data("HTTP/1.1 407 Proxy Authentication Required\r\n\r\n".utf8))
        let response = try LoopbackTCPFixture.read(client, until: Data("\r\n\r\n".utf8))
        #expect(throws: HTTPProxyCodecError.proxyRejected(status: 407)) {
            try connector.validate(response: response)
        }
        client.cancel()
        _ = destination
    }

    @Test("SOCKS5 connector completes greeting, CONNECT, and payload round-trip")
    func socks5Loopback() throws {
        let server = try LoopbackTCPFixture()
        defer { server.stop() }
        let target = try OutboundNodeTarget(protocolName: "socks5", host: "127.0.0.1", port: server.port)
        let destination = SOCKS5Endpoint(address: try SOCKS5Address(domain: "example.com"), port: 443)
        let client = NativeSOCKS5OutboundConnector(target: target).makeConnection()
        try LoopbackTCPFixture.start(client)
        try LoopbackTCPFixture.send(client, data: try SOCKS5Codec.encodeGreeting(methods: [.noAuthenticationRequired]))
        let greeting = try server.read(atLeast: 3)
        #expect(greeting.first == 5)
        #expect(greeting[2] == SOCKS5AuthenticationMethod.noAuthenticationRequired.rawValue)
        try server.send(Data([5, 0]))
        #expect(try LoopbackTCPFixture.read(client, atLeast: 2).suffix(2) == Data([5, 0]))

        let command = try SOCKS5Codec.encodeCommandRequest(
            SOCKS5CommandRequest(command: .connect, endpoint: destination)
        )
        try LoopbackTCPFixture.send(client, data: command)
        let request = try server.read(atLeast: command.count)
        #expect(try SOCKS5Codec.decodeCommandRequest(Data(request.suffix(command.count))).endpoint == destination)
        let reply = Data([5, 0, 0, 1, 127, 0, 0, 1, 0x01, 0xbb])
        try server.send(reply)
        #expect(try SOCKS5Codec.decodeCommandReply(LoopbackTCPFixture.read(client, atLeast: reply.count)).code == .succeeded)
        try LoopbackTCPFixture.send(client, data: Data("ping".utf8))
        #expect(try server.read(atLeast: 4).suffix(4) == Data("ping".utf8))
        try server.send(Data("pong".utf8))
        #expect(try LoopbackTCPFixture.read(client, atLeast: 4).suffix(4) == Data("pong".utf8))
        client.cancel()
    }

    @Test("VLESS plain TCP sends the request before application payload")
    func vlessPlainTCPLoopback() throws {
        let server = try LoopbackTCPFixture()
        defer { server.stop() }
        let target = try OutboundNodeTarget(
            protocolName: "vless", host: "127.0.0.1", port: server.port,
            parameters: ["uuid": "00000000-0000-0000-0000-000000000001"]
        )
        let destination = SOCKS5Endpoint(address: try SOCKS5Address(domain: "example.com"), port: 443)
        let connector = NativeVLESSOutboundConnector(target: target)
        let client = connector.makeConnection()
        try LoopbackTCPFixture.start(client)
        let handshake = try connector.handshake(for: destination)
        try LoopbackTCPFixture.send(client, data: handshake)
        let received = try server.read(atLeast: handshake.count)
        #expect(Data(received.prefix(handshake.count)) == handshake)
        #expect(received.first == VLESSCodec.version)
        try LoopbackTCPFixture.send(client, data: Data("ping".utf8))
        #expect(try server.read(atLeast: 4).suffix(4) == Data("ping".utf8))
        try server.send(Data("pong".utf8))
        #expect(try LoopbackTCPFixture.read(client, atLeast: 4).suffix(4) == Data("pong".utf8))
        client.cancel()
    }

    @Test("VLESS WebSocket bridge masks client payload and decodes segmented server frames")
    func vlessWebSocketBridgeLoopback() throws {
        let server = try LoopbackTCPFixture()
        defer { server.stop() }
        let target = try OutboundNodeTarget(
            protocolName: "vless", host: "127.0.0.1", port: server.port,
            parameters: [
                "uuid": "00000000-0000-0000-0000-000000000001",
                "network": "ws", "ws-path": "/vless"
            ]
        )
        let destination = SOCKS5Endpoint(address: try SOCKS5Address(domain: "example.com"), port: 443)
        let connector = NativeVLESSWebSocketRelayConnector(target: target)
        let client = connector.makeConnection(to: nil)
        try LoopbackTCPFixture.start(client)
        try LoopbackTCPFixture.send(client, data: try connector.responseHandshake(for: destination))
        let upgrade = try server.read(until: Data("\r\n\r\n".utf8))
        let lines = String(decoding: upgrade, as: UTF8.self).split(separator: "\r\n")
        let key = String(try #require(lines.first(where: { $0.lowercased().hasPrefix("sec-websocket-key:") }))
            .split(separator: ":", maxSplits: 1)[1].trimmingCharacters(in: .whitespaces))
        let accept = Data(Insecure.SHA1.hash(data: Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8))).base64EncodedString()
        try server.send(Data(("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: \(accept)\r\n\r\n").utf8))
        _ = try LoopbackTCPFixture.read(client, until: Data("\r\n\r\n".utf8))
        try LoopbackTCPFixture.send(client, data: try connector.postResponseHandshake(for: destination)!)
        let destinationFrame = try server.read(atLeast: 2)
        #expect(destinationFrame[0] & 0x80 != 0)
        #expect(destinationFrame[1] & 0x80 != 0, "client VLESS WS frames must be masked")

        let codec = try #require(connector.makeStreamCodec(for: destination) as? VLESSWebSocketStreamCodec)
        try LoopbackTCPFixture.send(client, data: try codec.encode(Data("ping".utf8)))
        let applicationFrame = try server.read(atLeast: 2)
        #expect(applicationFrame[0] == 0x82)
        #expect(applicationFrame[1] & 0x80 != 0, "application payload must remain masked")

        // Send two unmasked binary frames in one TCP write, then feed the
        // decoder in small segments to prove framing is independent of reads.
        let serverFrames = Data([0x82, 0x04]) + Data("pong".utf8) + Data([0x82, 0x05]) + Data("again".utf8)
        try server.send(serverFrames)
        var decoded = [Data]()
        for _ in 0..<20 where decoded.count < 2 {
            decoded.append(contentsOf: try codec.decode(LoopbackTCPFixture.read(client, atLeast: 1)))
        }
        #expect(decoded == [Data("pong".utf8), Data("again".utf8)])
        client.cancel()
    }

    @Test("Shadowsocks AEAD stream authenticates and round-trips framed bytes")
    func shadowsocksLoopback() throws {
        let server = try LoopbackTCPFixture()
        defer { server.stop() }
        let target = try OutboundNodeTarget(
            protocolName: "shadowsocks", host: "127.0.0.1", port: server.port,
            parameters: ["method": "aes-256-gcm", "password": "fixture-password"]
        )
        let destination = try ShadowsocksAEADStreamEncoder.encodeDestination(host: "example.com", port: 443)
        var clientEncoder = try ShadowsocksAEADStreamEncoder(
            methodName: "aes-256-gcm", password: "fixture-password", salt: Data(repeating: 0x11, count: 32)
        )
        var serverDecoder = try ShadowsocksAEADStreamDecoder(methodName: "aes-256-gcm", password: "fixture-password")
        var clientDecoder = try ShadowsocksAEADStreamDecoder(methodName: "aes-256-gcm", password: "fixture-password")
        var serverEncoder = try ShadowsocksAEADStreamEncoder(
            methodName: "aes-256-gcm", password: "fixture-password", salt: Data(repeating: 0x22, count: 32)
        )
        let client = NativeShadowsocksRelayConnector(
            target: target,
            destination: try SOCKS5Endpoint(
                address: SOCKS5Address(domain: "example.com"),
                port: 443
            )
        ).makeConnection(to: nil)
        try LoopbackTCPFixture.start(client)
        try LoopbackTCPFixture.send(client, data: clientEncoder.encode(destination) + clientEncoder.encode(Data("ping".utf8)))
        var frames = [Data]()
        // TCP is a stream: one write may be split into any number of reads.
        // Keep feeding the decoder until both the destination and payload
        // frames have arrived instead of relying on a packet-sized read.
        for _ in 0..<20 where frames.count < 2 {
            frames.append(contentsOf: try serverDecoder.append(server.read(atLeast: 1)))
        }
        #expect(frames.count == 2)
        #expect(frames[0] == destination)
        #expect(frames[1] == Data("ping".utf8))
        try server.send(serverEncoder.encode(Data("pong".utf8)))
        var responses = [Data]()
        for _ in 0..<20 where responses.isEmpty {
            responses.append(contentsOf: try clientDecoder.append(LoopbackTCPFixture.read(client, atLeast: 1)))
        }
        #expect(responses == [Data("pong".utf8)])
        client.cancel()
    }
}

/// Small synchronous NWConnection fixture.  Synchronous waits are intentional
/// here: each test has a bounded five-second timeout and never touches a
/// process, DNS resolver, or externally configured proxy.
private final class LoopbackTCPFixture: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "one.leaper.mclash.native-loopback-fixture")
    private let ready = DispatchSemaphore(value: 0)
    private let accepted = DispatchSemaphore(value: 0)
    private let dataAvailable = DispatchSemaphore(value: 0)
    private var connection: NWConnection?
    private var buffer = Data()
    private let lock = NSLock()
    private(set) var port: UInt16 = 0

    init() throws {
        listener = try NWListener(using: .tcp, on: .any)
        listener.stateUpdateHandler = { [weak self] state in
            if case .ready = state { self?.ready.signal() }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            self.connection = connection
            connection.stateUpdateHandler = { _ in }
            connection.start(queue: self.queue)
            self.accepted.signal()
            self.receiveNext(connection)
        }
        listener.start(queue: queue)
        guard ready.wait(timeout: .now() + 5) == .success,
              let port = listener.port?.rawValue, port > 0 else {
            throw FixtureError.timeout("listener readiness")
        }
        self.port = port
    }

    func stop() { connection?.cancel(); listener.cancel() }

    func send(_ data: Data) throws {
        guard accepted.wait(timeout: .now() + 5) == .success || connection != nil,
              let connection else { throw FixtureError.timeout("accept") }
        let done = DispatchSemaphore(value: 0)
        connection.send(content: data, completion: .contentProcessed { error in
            if let error { _ = error }
            done.signal()
        })
        guard done.wait(timeout: .now() + 5) == .success else { throw FixtureError.timeout("send") }
    }

    func read(until marker: Data) throws -> Data {
        for _ in 0..<100 {
            lock.lock(); let current = buffer; lock.unlock()
            if current.range(of: marker) != nil {
                lock.lock(); buffer.removeAll(); lock.unlock()
                return current
            }
            guard dataAvailable.wait(timeout: .now() + 0.05) == .success else { continue }
        }
        throw FixtureError.timeout("read marker")
    }

    func read(atLeast count: Int) throws -> Data {
        for _ in 0..<100 {
            lock.lock(); let current = buffer; lock.unlock()
            if current.count >= count {
                lock.lock(); buffer.removeAll(); lock.unlock()
                return current
            }
            guard dataAvailable.wait(timeout: .now() + 0.05) == .success else { continue }
        }
        throw FixtureError.timeout("read bytes")
    }

    private func receiveNext(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, complete, _ in
            guard let self else { return }
            if let data, !data.isEmpty { self.lock.lock(); self.buffer.append(data); self.lock.unlock(); self.dataAvailable.signal() }
            if !complete { self.receiveNext(connection) }
        }
    }

    static func start(_ connection: NWConnection) throws {
        let semaphore = DispatchSemaphore(value: 0)
        let failure = ErrorBox<NWError>()
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                semaphore.signal()
            case .failed(let error):
                failure.set(error)
                semaphore.signal()
            default: break
            }
        }
        connection.start(queue: DispatchQueue(label: "one.leaper.mclash.native-loopback-client"))
        guard semaphore.wait(timeout: .now() + 5) == .success else { throw FixtureError.timeout("connection readiness") }
        if let failure = failure.value { throw failure }
    }

    static func send(_ connection: NWConnection, data: Data) throws {
        let semaphore = DispatchSemaphore(value: 0)
        connection.send(content: data, completion: .contentProcessed { _ in semaphore.signal() })
        guard semaphore.wait(timeout: .now() + 5) == .success else { throw FixtureError.timeout("client send") }
    }

    static func read(_ connection: NWConnection, until marker: Data) throws -> Data {
        var result = Data()
        for _ in 0..<100 {
            if result.range(of: marker) != nil { return result }
            let semaphore = DispatchSemaphore(value: 0)
            let box = ReadBox()
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, isComplete, _ in
                box.append(data)
                box.complete = isComplete
                semaphore.signal()
            }
            guard semaphore.wait(timeout: .now() + 0.05) == .success else { continue }
            result.append(contentsOf: box.data)
            if box.complete { break }
        }
        guard result.range(of: marker) != nil else { throw FixtureError.timeout("client read marker") }
        return result
    }

    static func read(_ connection: NWConnection, atLeast count: Int) throws -> Data {
        var result = Data()
        for _ in 0..<100 {
            if result.count >= count { return result }
            let semaphore = DispatchSemaphore(value: 0)
            let box = ReadBox()
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, isComplete, _ in
                box.append(data)
                box.complete = isComplete
                semaphore.signal()
            }
            guard semaphore.wait(timeout: .now() + 0.05) == .success else { continue }
            result.append(contentsOf: box.data)
            if box.complete { break }
        }
        guard result.count >= count else { throw FixtureError.timeout("client read bytes") }
        return result
    }
}

private enum FixtureError: Error { case timeout(String) }

private final class ErrorBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value?

    var value: Value? {
        lock.lock(); defer { lock.unlock() }
        return stored
    }

    func set(_ value: Value) {
        lock.lock(); stored = value; lock.unlock()
    }
}

private final class ReadBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = Data()
    private var finished = false

    var data: Data {
        lock.lock(); defer { lock.unlock() }
        return stored
    }

    var complete: Bool {
        get {
            lock.lock(); defer { lock.unlock() }
            return finished
        }
        set {
            lock.lock(); finished = newValue; lock.unlock()
        }
    }

    func append(_ data: Data?) {
        guard let data, !data.isEmpty else { return }
        lock.lock(); stored.append(data); lock.unlock()
    }
}
