import Foundation

/// Incremental decoder for the bounded HTTP/3 frame subset used by the native
/// Hysteria2 session. It tolerates arbitrary transport segmentation while
/// keeping buffered bytes and frame sizes bounded.
public struct HTTP3FrameDecoder: Sendable {
    public let maximumBufferedBytes: Int
    private var buffer = Data()

    public init(maximumBufferedBytes: Int = 2 * 1024 * 1024) {
        self.maximumBufferedBytes = maximumBufferedBytes
    }

    public mutating func append(_ data: Data) throws -> [HTTP3Frame] {
        guard buffer.count + data.count <= maximumBufferedBytes else {
            throw HTTP3FrameCodecError.oversized
        }
        buffer.append(data)
        var frames: [HTTP3Frame] = []
        while let frame = try decodeOneIfComplete() {
            frames.append(frame)
        }
        return frames
    }

    private mutating func decodeOneIfComplete() throws -> HTTP3Frame? {
        guard let (_, typeLength) = try decodeVarintIfComplete(buffer, offset: 0) else { return nil }
        guard let (length, lengthLength) = try decodeVarintIfComplete(buffer, offset: typeLength) else { return nil }
        guard length <= UInt64(HTTP3FrameCodec.maximumFrameBytes) else { throw HTTP3FrameCodecError.oversized }
        let headerLength = typeLength + lengthLength
        let totalLength = headerLength + Int(length)
        guard buffer.count >= totalLength else { return nil }
        let frameData = buffer.prefix(totalLength)
        buffer.removeFirst(totalLength)
        return try HTTP3FrameCodec.decode(frameData)
    }

    private func decodeVarintIfComplete(_ data: Data, offset: Int) throws -> (UInt64, Int)? {
        guard offset < data.count else { return nil }
        let firstIndex = data.index(data.startIndex, offsetBy: offset)
        let first = data[firstIndex]
        let length = 1 << Int(first >> 6)
        guard offset + length <= data.count else { return nil }
        var value = UInt64(first & 0x3f)
        for index in 1..<length {
            let byteIndex = data.index(firstIndex, offsetBy: index)
            value = (value << 8) | UInt64(data[byteIndex])
        }
        return (value, length)
    }
}
