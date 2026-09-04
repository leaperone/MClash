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

    @Test("Preserves frame order when one transport read contains multiple frames")
    func multipleFrames() throws {
        let first = try HTTP3FrameCodec.encode(
            HTTP3Frame(type: .headers, payload: Data([0x01]))
        )
        let second = try HTTP3FrameCodec.encode(
            HTTP3Frame(type: .data, payload: Data("body".utf8))
        )
        var decoder = HTTP3FrameDecoder()
        let frames = try decoder.append(first + second)
        guard frames.count == 2 else {
            Issue.record("Decoded HTTP/3 frames did not preserve transport order")
            return
        }
        if frames[0].type != .headers || frames[0].payload != Data([0x01]) {
            Issue.record("The first decoded HTTP/3 frame was not the expected headers frame")
        }
        if frames[1].type != .data || frames[1].payload != Data("body".utf8) {
            Issue.record("The second decoded HTTP/3 frame was not the expected data frame")
        }
    }

    @Test("Rejects an unsupported frame type only once its complete frame arrives")
    func unsupportedFrameAfterSegmentation() throws {
        // Type 0x02 is not part of the deliberately bounded subset.
        var decoder = HTTP3FrameDecoder()
        #expect(try decoder.append(Data([0x02])).isEmpty)
        #expect(throws: HTTP3FrameCodecError.unsupportedType(0x02)) {
            try decoder.append(Data([0x00]))
        }
    }
}
