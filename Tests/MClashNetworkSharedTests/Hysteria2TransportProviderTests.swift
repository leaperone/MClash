import Foundation
import Testing
@testable import MClashNetworkShared

@Suite("Hysteria2 transport boundary")
struct Hysteria2TransportProviderTests {
    @Test("Authenticates once and retains independent bidirectional streams")
    func multiplexesStreams() async throws {
        let fake = FakeProvider(); let transport = Hysteria2MultiplexedTransport(provider: fake)
        async let one = transport.openStream(); async let two = transport.openStream()
        let first = try await one; let second = try await two
        #expect(first != second); #expect(await fake.authentications == 1); #expect(await fake.opened == 2)
        try await transport.send(Data("one".utf8), on: first)
        try await transport.send(Data("two".utf8), on: second)
        #expect(await fake.sent.count == 2)
        #expect(try await transport.receive(on: first) == Data("response".utf8))
        await transport.closeStream(first); await transport.close(); #expect(await fake.closed)
    }

    @Test("Uses a distinct datagram channel and rejects work after close")
    func datagramLifecycle() async throws {
        let fake = FakeProvider()
        let transport = Hysteria2MultiplexedTransport(provider: fake)
        try await transport.sendDatagram(Data("udp".utf8))
        #expect(try await transport.receiveDatagram() == Data("reply".utf8))
        #expect(await fake.datagrams == [Data("udp".utf8)])
        #expect(await fake.authentications == 1)

        await transport.close()
        await #expect(throws: Hysteria2TransportError.closed) {
            _ = try await transport.openStream()
        }
        await #expect(throws: Hysteria2TransportError.closed) {
            try await transport.sendDatagram(Data("late".utf8))
        }
    }

    @Test("Keeps a half-closed stream readable and bounds stream writes")
    func halfCloseAndBounds() async throws {
        let fake = FakeProvider()
        let transport = Hysteria2MultiplexedTransport(
            provider: fake,
            maxConcurrentStreams: 1,
            maxPayloadSize: 8
        )
        let stream = try await transport.openStream()
        await transport.closeStream(stream, halfClose: true)
        #expect(try await transport.receive(on: stream) == Data("response".utf8))
        await #expect(throws: Hysteria2TransportError.halfClosed) {
            try await transport.send(Data("late".utf8), on: stream)
        }
        await #expect(throws: Hysteria2TransportError.payloadTooLarge) {
            try await transport.send(Data(repeating: 0, count: 9), on: stream)
        }
        await transport.closeStream(stream)
        await #expect(throws: Hysteria2TransportError.closed) {
            try await transport.send(Data("x".utf8), on: stream)
        }
    }

    @Test("Rejects a second stream at the configured limit")
    func streamLimit() async throws {
        let fake = FakeProvider()
        let transport = Hysteria2MultiplexedTransport(provider: fake, maxConcurrentStreams: 1)
        _ = try await transport.openStream()
        await #expect(throws: Hysteria2TransportError.streamLimitReached) {
            _ = try await transport.openStream()
        }
    }
}

private actor FakeProvider: Hysteria2TransportProvider {
    var authentications = 0; var opened = 0; var sent: [Data] = []
    var datagrams: [Data] = []; var closed = false
    func authenticate() async throws -> Bool { authentications += 1; return true }
    func openBidirectionalStream() async throws -> any Hysteria2StreamTransport { opened += 1; return FakeStream(owner: self) }
    func sendDatagram(_ data: Data) async throws { datagrams.append(data) }
    func receiveDatagram() async throws -> Data? { Data("reply".utf8) }
    func close() async { closed = true }
    func record(_ data: Data) { sent.append(data) }
}

private final class FakeStream: Hysteria2StreamTransport, @unchecked Sendable {
    let owner: FakeProvider
    init(owner: FakeProvider) { self.owner = owner }
    func send(_ data: Data) async throws { await owner.record(data) }
    func receive() async throws -> Data? { Data("response".utf8) }
    func halfClose() async {}
    func close() async {}
}
