import Foundation

public enum HTTP3FrameType: UInt64, Sendable {
    case data = 0x0
    case headers = 0x1
}

public struct HTTP3Frame: Equatable, Sendable {
    public let type: HTTP3FrameType
    public let payload: Data
    public init(type: HTTP3FrameType, payload: Data) {
        self.type = type
        self.payload = payload
    }
}

public enum HTTP3FrameCodecError: Error, Equatable, Sendable {
    case truncated
    case unsupportedType(UInt64)
    case oversized
}

public enum HTTP3FrameCodec: Sendable {
    public static let maximumFrameBytes = 1 * 1024 * 1024

    public static func encode(_ frame: HTTP3Frame) throws -> Data {
        guard frame.payload.count <= maximumFrameBytes else { throw HTTP3FrameCodecError.oversized }
        return encodeVarint(frame.type.rawValue)
            + encodeVarint(UInt64(frame.payload.count))
            + frame.payload
    }

    public static func decode(_ data: Data) throws -> HTTP3Frame {
        var offset = 0
        let type = try decodeVarint(data, offset: &offset)
        let length = try decodeVarint(data, offset: &offset)
        guard length <= maximumFrameBytes else { throw HTTP3FrameCodecError.oversized }
        guard offset + Int(length) == data.count else { throw HTTP3FrameCodecError.truncated }
        guard let frameType = HTTP3FrameType(rawValue: type) else {
            throw HTTP3FrameCodecError.unsupportedType(type)
        }
        return HTTP3Frame(type: frameType, payload: Data(data[offset...]))
    }

    private static func encodeVarint(_ value: UInt64) -> Data {
        if value < (1 << 6) { return Data([UInt8(value)]) }
        if value < (1 << 14) {
            let encoded = UInt16(value) | 0x4000
            return Data([UInt8(encoded >> 8), UInt8(encoded)])
        }
        if value < (1 << 30) {
            let encoded = UInt32(value) | 0x80000000
            return Data([UInt8(encoded >> 24), UInt8(encoded >> 16), UInt8(encoded >> 8), UInt8(encoded)])
        }
        let encoded = value | 0xc000000000000000
        return Data((0..<8).reversed().map { UInt8(encoded >> (UInt64($0) * 8)) })
    }

    private static func decodeVarint(_ data: Data, offset: inout Int) throws -> UInt64 {
        guard offset < data.count else { throw HTTP3FrameCodecError.truncated }
        let first = data[offset]
        let length = 1 << Int(first >> 6)
        guard offset + length <= data.count else { throw HTTP3FrameCodecError.truncated }
        var value = UInt64(first & 0x3f)
        for index in 1..<length { value = (value << 8) | UInt64(data[offset + index]) }
        offset += length
        return value
    }
}
