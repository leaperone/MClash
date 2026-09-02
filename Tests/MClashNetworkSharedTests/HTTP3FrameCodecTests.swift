import Foundation
import Testing
@testable import MClashNetworkShared

@Suite("HTTP/3 frame codec")
struct HTTP3FrameCodecTests {
    @Test("Round-trips HEADERS and DATA frames")
    func roundTrips() throws {
        for frame in [
            HTTP3Frame(type: .headers, payload: Data([0x01, 0x02])),
            HTTP3Frame(type: .data, payload: Data("payload".utf8)),
        ] {
            #expect(try HTTP3FrameCodec.decode(HTTP3FrameCodec.encode(frame)) == frame)
        }
    }

    @Test("Rejects truncated, unsupported, and oversized frames")
    func rejectsInvalidFrames() throws {
        #expect(throws: HTTP3FrameCodecError.truncated) {
            try HTTP3FrameCodec.decode(Data([0x01, 0x05, 0x01]))
        }
        #expect(throws: HTTP3FrameCodecError.unsupportedType(0x02)) {
            try HTTP3FrameCodec.decode(Data([0x02, 0x00]))
        }
        #expect(throws: HTTP3FrameCodecError.oversized) {
            try HTTP3FrameCodec.encode(
                HTTP3Frame(type: .data, payload: Data(repeating: 0, count: HTTP3FrameCodec.maximumFrameBytes + 1))
            )
        }
    }
}
