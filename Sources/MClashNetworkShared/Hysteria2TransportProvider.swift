import Foundation

/// Injectable transport boundary for Hysteria2. A production adapter may use
/// Network.framework QUIC; tests use deterministic fakes. Authentication is
/// deliberately separate from per-request streams and UDP datagrams.
public protocol Hysteria2TransportProvider: Sendable {
    associatedtype Stream: Sendable
    func authenticate() async throws -> Bool
    func openStream() async throws -> Stream
    func send(_ data: Data, on stream: Stream) async throws
    func close(_ stream: Stream)
    func sendDatagram(_ data: Data) async throws
    func close() async
}

public actor Hysteria2MultiplexedTransport<Provider: Hysteria2TransportProvider> {
    private let provider: Provider
    private var authenticated = false
    private var closed = false

    public init(provider: Provider) { self.provider = provider }

    public func authenticate() async throws {
        guard !closed else { throw Hysteria2TransportError.closed }
        guard !authenticated else { return }
        guard try await provider.authenticate() else { throw Hysteria2TransportError.authenticationFailed }
        authenticated = true
    }

    public func sendTCP(_ data: Data) async throws {
        try await authenticate()
        let stream = try await provider.openStream()
        defer { provider.close(stream) }
        try await provider.send(data, on: stream)
    }

    public func sendUDP(_ data: Data) async throws {
        try await authenticate()
        try await provider.sendDatagram(data)
    }

    public func close() async {
        guard !closed else { return }
        closed = true
        await provider.close()
    }
}

public enum Hysteria2TransportError: Error, Equatable, Sendable {
    case authenticationFailed
    case closed
}
