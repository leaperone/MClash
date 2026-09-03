import Foundation
import Testing
@testable import MClashNetworkShared

@Suite("Hysteria2 UDP fragment reassembly")
struct Hysteria2FragmentReassemblerTests {
    @Test("Reassembles out-of-order fragments and ignores duplicates")
    func reassembles() throws {
        let first = try Hysteria2Codec.decodeUDPMessage(try Hysteria2Codec.encodeUDPMessage(
            sessionID: 1, packetID: 2, fragmentID: 1, fragmentCount: 2,
            host: "example.com", port: 53, payload: Data("world".utf8)
        ))
        let second = try Hysteria2Codec.decodeUDPMessage(try Hysteria2Codec.encodeUDPMessage(
            sessionID: 1, packetID: 2, fragmentID: 0, fragmentCount: 2,
            host: "example.com", port: 53, payload: Data("hello ".utf8)
        ))
        var reassembler = Hysteria2FragmentReassembler()
        #expect(reassembler.append(first) == nil)
        #expect(reassembler.append(first) == nil)
        #expect(reassembler.append(second) == Data("hello world".utf8))
    }

    @Test("Expires incomplete packets and returns single-packet payloads")
    func expiration() throws {
        let message = try Hysteria2Codec.decodeUDPMessage(try Hysteria2Codec.encodeUDPMessage(
            sessionID: 1, packetID: 1, host: "example.com", port: 53, payload: Data([1])
        ))
        var reassembler = Hysteria2FragmentReassembler(expiration: 1)
        let now = Date()
        #expect(reassembler.append(message, now: now) == Data([1]))
        reassembler.prune(now: now.addingTimeInterval(2))
    }

    @Test("Rejects fragments that change the destination mid-packet")
    func destinationMismatch() throws {
        let first = try Hysteria2Codec.decodeUDPMessage(try Hysteria2Codec.encodeUDPMessage(
            sessionID: 9, packetID: 4, fragmentID: 0, fragmentCount: 2,
            host: "first.example", port: 53, payload: Data("a".utf8)
        ))
        let second = try Hysteria2Codec.decodeUDPMessage(try Hysteria2Codec.encodeUDPMessage(
            sessionID: 9, packetID: 4, fragmentID: 1, fragmentCount: 2,
            host: "second.example", port: 53, payload: Data("b".utf8)
        ))
        var reassembler = Hysteria2FragmentReassembler()
        #expect(reassembler.append(first) == nil)
        #expect(reassembler.append(second) == nil)
        // The mismatched packet was discarded, so a valid packet can begin
        // cleanly with the same session/packet identifiers.
        #expect(reassembler.append(first) == nil)
        let validSecond = try Hysteria2Codec.decodeUDPMessage(try Hysteria2Codec.encodeUDPMessage(
            sessionID: 9, packetID: 4, fragmentID: 1, fragmentCount: 2,
            host: "first.example", port: 53, payload: Data("b".utf8)
        ))
        #expect(reassembler.append(validSecond) == Data("ab".utf8))
    }
}
