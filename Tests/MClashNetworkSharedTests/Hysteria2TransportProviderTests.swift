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
        await transport.closeStream(first); await transport.close(); #expect(await fake.closed)
    }
}

private actor FakeProvider: Hysteria2TransportProvider {
    var authentications = 0; var opened = 0; var sent: [Data] = []; var closed = false
    func authenticate() async throws -> Bool { authentications += 1; return true }
    func openBidirectionalStream() async throws -> any Hysteria2StreamTransport { opened += 1; return FakeStream(owner: self) }
    func sendDatagram(_ data: Data) async throws { sent.append(data) }
    func receiveDatagram() async throws -> Data? { nil }
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
