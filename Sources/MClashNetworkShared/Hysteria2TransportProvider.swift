import Foundation

public protocol Hysteria2StreamTransport: Sendable {
    func send(_ data: Data) async throws
    func receive() async throws -> Data?
    func halfClose() async
    func close() async
}

public protocol Hysteria2TransportProvider: Sendable {
    func authenticate() async throws -> Bool
    func openBidirectionalStream() async throws -> any Hysteria2StreamTransport
    func sendDatagram(_ data: Data) async throws
    func receiveDatagram() async throws -> Data?
    func close() async
}

public enum Hysteria2TransportError: Error, Equatable, Sendable {
    case authenticationFailed, closed
}

public actor Hysteria2MultiplexedTransport {
    public struct StreamID: Hashable, Sendable { fileprivate let rawValue = UUID(); public init() {} }
    private let provider: any Hysteria2TransportProvider
    private var authenticated = false
    private var closed = false
    private var streams: [StreamID: any Hysteria2StreamTransport] = [:]

    public init(provider: any Hysteria2TransportProvider) { self.provider = provider }
    private func ensureAuthenticated() async throws {
        guard !closed else { throw Hysteria2TransportError.closed }
        guard !authenticated else { return }
        guard try await provider.authenticate() else { throw Hysteria2TransportError.authenticationFailed }
        authenticated = true
    }
    public func openStream() async throws -> StreamID {
        try await ensureAuthenticated(); let id = StreamID()
        streams[id] = try await provider.openBidirectionalStream(); return id
    }
    public func send(_ data: Data, on id: StreamID) async throws {
        guard let stream = streams[id] else { throw Hysteria2TransportError.closed }; try await stream.send(data)
    }
    public func receive(on id: StreamID) async throws -> Data? {
        guard let stream = streams[id] else { throw Hysteria2TransportError.closed }; return try await stream.receive()
    }
    public func closeStream(_ id: StreamID, halfClose: Bool = false) async {
        guard let stream = streams.removeValue(forKey: id) else { return }
        if halfClose { await stream.halfClose() } else { await stream.close() }
    }
    public func sendDatagram(_ data: Data) async throws { try await ensureAuthenticated(); try await provider.sendDatagram(data) }
    public func receiveDatagram() async throws -> Data? { try await ensureAuthenticated(); return try await provider.receiveDatagram() }
    public func close() async {
        guard !closed else { return }; closed = true
        let active = streams.values; streams.removeAll()
        for stream in active { await stream.close() }; await provider.close()
    }
}
