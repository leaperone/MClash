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
    case authenticationFailed, closed, streamLimitReached, payloadTooLarge, halfClosed, writeInProgress
}

public actor Hysteria2MultiplexedTransport {
    public struct StreamID: Hashable, Sendable { fileprivate let rawValue = UUID(); public init() {} }
    private let provider: any Hysteria2TransportProvider
    private let maxConcurrentStreams: Int
    private let maxPayloadSize: Int
    private var authenticated = false
    private var authenticationTask: Task<Bool, Error>?
    private var closed = false
    private var streams: [StreamID: any Hysteria2StreamTransport] = [:]
    private var halfClosedStreams: Set<StreamID> = []
    private var openingStreams = 0
    private var writingStreams: Set<StreamID> = []

    /// The limits are deliberately enforced at this boundary.  A QUIC
    /// connection can multiplex many streams, but an intercepted flow must
    /// never be allowed to create an unbounded number of streams or enqueue
    /// arbitrarily large writes while the peer applies backpressure.
    public init(
        provider: any Hysteria2TransportProvider,
        maxConcurrentStreams: Int = 64,
        maxPayloadSize: Int = 1_048_576
    ) {
        self.provider = provider
        self.maxConcurrentStreams = max(1, maxConcurrentStreams)
        self.maxPayloadSize = max(1, maxPayloadSize)
    }
    private func ensureAuthenticated() async throws {
        guard !closed else { throw Hysteria2TransportError.closed }
        guard !authenticated else { return }
        let task: Task<Bool, Error>
        if let authenticationTask {
            task = authenticationTask
        } else {
            let created = Task { [provider] in
                try await provider.authenticate()
            }
            authenticationTask = created
            task = created
        }
        do {
            guard try await task.value else {
                throw Hysteria2TransportError.authenticationFailed
            }
            authenticated = true
            if authenticationTask != nil {
                authenticationTask = nil
            }
        } catch {
            if authenticationTask != nil {
                authenticationTask = nil
            }
            throw error
        }
    }
    public func openStream() async throws -> StreamID {
        try await ensureAuthenticated()
        guard streams.count + openingStreams < maxConcurrentStreams else {
            throw Hysteria2TransportError.streamLimitReached
        }
        let id = StreamID()
        openingStreams += 1
        defer { openingStreams -= 1 }
        let stream = try await provider.openBidirectionalStream()
        // A provider may complete an opening operation after its caller was
        // cancelled.  Do not leak that stream into the session.
        guard !Task.isCancelled, !closed else {
            await stream.close()
            throw Hysteria2TransportError.closed
        }
        streams[id] = stream
        return id
    }
    public func send(_ data: Data, on id: StreamID) async throws {
        guard data.count <= maxPayloadSize else { throw Hysteria2TransportError.payloadTooLarge }
        guard !closed, let stream = streams[id] else { throw Hysteria2TransportError.closed }
        guard !halfClosedStreams.contains(id) else { throw Hysteria2TransportError.halfClosed }
        guard writingStreams.insert(id).inserted else { throw Hysteria2TransportError.writeInProgress }
        defer { writingStreams.remove(id) }
        try Task.checkCancellation()
        try await stream.send(data)
    }
    public func receive(on id: StreamID) async throws -> Data? {
        guard !closed, let stream = streams[id] else { throw Hysteria2TransportError.closed }
        let data = try await stream.receive()
        guard data?.count ?? 0 <= maxPayloadSize else { throw Hysteria2TransportError.payloadTooLarge }
        return data
    }
    public func closeStream(_ id: StreamID, halfClose: Bool = false) async {
        guard let stream = streams[id] else { return }
        if halfClose {
            guard halfClosedStreams.insert(id).inserted else { return }
            await stream.halfClose()
        } else {
            streams.removeValue(forKey: id)
            halfClosedStreams.remove(id)
            writingStreams.remove(id)
            await stream.close()
        }
    }
    public func sendDatagram(_ data: Data) async throws {
        guard data.count <= maxPayloadSize else { throw Hysteria2TransportError.payloadTooLarge }
        try await ensureAuthenticated(); try Task.checkCancellation(); try await provider.sendDatagram(data)
    }
    public func receiveDatagram() async throws -> Data? { try await ensureAuthenticated(); return try await provider.receiveDatagram() }
    public func close() async {
        guard !closed else { return }; closed = true
        authenticationTask?.cancel(); authenticationTask = nil
        let active = streams.values; streams.removeAll(); halfClosedStreams.removeAll(); writingStreams.removeAll()
        for stream in active { await stream.close() }; await provider.close()
    }
}
