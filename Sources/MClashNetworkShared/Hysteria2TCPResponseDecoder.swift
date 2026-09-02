import Foundation

public struct Hysteria2TCPResponseDecoder: Sendable {
    private var buffer = Data()
    private(set) var isComplete = false

    public init() {}

    public mutating func append(_ data: Data) throws -> (accepted: Bool, message: String)? {
        guard !isComplete else { throw Hysteria2CodecError.invalidResponse }
        buffer.append(data)
        guard buffer.count >= 1 else { return nil }
        let status = buffer[0]
        var offset = 1
        guard let messageLength = decodeVarint(offset: &offset) else { return nil }
        guard messageLength <= 4096 else { throw Hysteria2CodecError.oversized }
        guard offset + Int(messageLength) <= buffer.count else { return nil }
        let messageData = buffer[offset..<(offset + Int(messageLength))]
        offset += Int(messageLength)
        guard let paddingLength = decodeVarint(offset: &offset) else { return nil }
        guard paddingLength <= 4096 else { throw Hysteria2CodecError.oversized }
        guard offset + Int(paddingLength) <= buffer.count else { return nil }
        guard offset + Int(paddingLength) == buffer.count else { throw Hysteria2CodecError.invalidResponse }
        isComplete = true
        let message = String(decoding: messageData, as: UTF8.self)
        if status != 0 { throw Hysteria2CodecError.serverRejected(message) }
        return (true, message)
    }

    private func decodeVarint(offset: inout Int) -> UInt64? {
        guard offset < buffer.count else { return nil }
        let first = buffer[offset]
        let length = 1 << Int(first >> 6)
        guard offset + length <= buffer.count else { return nil }
        var value = UInt64(first & 0x3f)
        for index in 1..<length { value = (value << 8) | UInt64(buffer[offset + index]) }
        offset += length
        return value
    }
}
