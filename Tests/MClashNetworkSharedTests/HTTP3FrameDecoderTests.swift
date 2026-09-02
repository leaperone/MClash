import Foundation
import Testing
@testable import MClashNetworkShared

@Suite("Incremental HTTP/3 frame decoder")
struct HTTP3FrameDecoderTests {
    @Test("Emits frames only after complete segmented input arrives")
    func segmentedInput() throws {
        let encoded = try HTTP3FrameCodec.encode(
            HTTP3Frame(type: .data, payload: Data("hello".utf8))
        )
        var decoder = HTTP3FrameDecoder()
        #expect(try decoder.append(encoded.prefix(1)).isEmpty)
        #expect(try decoder.append(encoded[1..<3]).isEmpty)
        let frames = try decoder.append(encoded.dropFirst(3))
        #expect(frames == [HTTP3Frame(type: .data, payload: Data("hello".utf8))])
    }

    @Test("Bounds buffered stream data")
    func boundsBuffer() throws {
        var decoder = HTTP3FrameDecoder(maximumBufferedBytes: 4)
        #expect(throws: HTTP3FrameCodecError.oversized) {
            try decoder.append(Data(repeating: 0, count: 5))
        }
    }
}
