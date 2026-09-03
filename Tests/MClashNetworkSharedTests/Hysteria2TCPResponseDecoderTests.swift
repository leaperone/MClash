import Foundation
import Testing
@testable import MClashNetworkShared

@Suite("Incremental Hysteria2 TCP response decoder")
struct Hysteria2TCPResponseDecoderTests {
    @Test("Waits for a complete response across arbitrary chunks")
    func chunks() throws {
        let response = Data([0x00, 0x02, 0x6f, 0x6b, 0x00])
        var decoder = Hysteria2TCPResponseDecoder()
        #expect(try decoder.append(response.prefix(2)) == nil)
        #expect(try decoder.append(response[2..<4]) == nil)
        #expect(try decoder.append(response.suffix(1))?.message == "ok")
        #expect(decoder.isComplete)
    }

    @Test("Handles every possible transport split without completing early")
    func everySplitPoint() throws {
        let response = Data([0x00, 0x02, 0x6f, 0x6b, 0x00])
        for split in 0..<response.count {
            var decoder = Hysteria2TCPResponseDecoder()
            #expect(try decoder.append(response.prefix(split)) == nil)
            #expect(try decoder.append(response.dropFirst(split))?.message == "ok")
            #expect(decoder.isComplete)
        }
    }

    @Test("Rejects bytes after a complete response")
    func rejectsAfterCompletion() throws {
        var decoder = Hysteria2TCPResponseDecoder()
        #expect(try decoder.append(Data([0x00, 0x00, 0x00]))?.accepted == true)
        #expect(throws: Hysteria2CodecError.invalidResponse) {
            try decoder.append(Data([0x00]))
        }
    }

    @Test("Rejects non-zero status and oversized message")
    func rejects() {
        var rejected = Hysteria2TCPResponseDecoder()
        #expect(throws: Hysteria2CodecError.serverRejected("denied")) {
            try rejected.append(Data([0x01, 0x06]) + Data("denied".utf8) + Data([0x00]))
        }
        var oversized = Hysteria2TCPResponseDecoder()
        #expect(throws: Hysteria2CodecError.oversized) {
            // QUIC varint 4097 (two-byte encoding: 0x50 0x01).
            try oversized.append(Data([0x00, 0x50, 0x01]))
        }
    }
}
