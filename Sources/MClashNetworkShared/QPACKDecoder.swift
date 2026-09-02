import Foundation

public enum QPACKDecoderError: Error, Equatable, Sendable {
    case truncated
    case unsupportedRepresentation
    case huffmanUnsupported
    case invalidField
}

/// Decoder for the deterministic literal-only QPACK subset emitted by
/// `QPACKEncoder`. Dynamic-table references and Huffman strings are rejected
/// explicitly instead of being guessed.
public enum QPACKDecoder: Sendable {
    public static func decodeLiteralFields(_ data: Data) throws -> [(String, String)] {
        guard data.count >= 2 else { throw QPACKDecoderError.truncated }
        guard data[0] == 0, data[1] == 0 else {
            throw QPACKDecoderError.unsupportedRepresentation
        }
        var offset = 2
        var fields: [(String, String)] = []
        while offset < data.count {
            let (nameLength, nameHuffman) = try decodeLength(data, offset: &offset, prefixBits: 3, huffmanBit: 0x08, expectedPattern: 0x20, expectedMask: 0xE0)
            guard !nameHuffman else { throw QPACKDecoderError.huffmanUnsupported }
            guard nameLength > 0, nameLength <= 255, offset + nameLength <= data.count else { throw QPACKDecoderError.invalidField }
            let name = String(decoding: data[offset..<(offset + nameLength)], as: UTF8.self)
            offset += nameLength
            let (valueLength, valueHuffman) = try decodeLength(data, offset: &offset, prefixBits: 7, huffmanBit: 0x80, expectedPattern: 0x00, expectedMask: 0x00)
            guard !valueHuffman else { throw QPACKDecoderError.huffmanUnsupported }
            guard valueLength <= 65_535, offset + valueLength <= data.count else { throw QPACKDecoderError.invalidField }
            let value = String(decoding: data[offset..<(offset + valueLength)], as: UTF8.self)
            offset += valueLength
            fields.append((name, value))
        }
        return fields
    }

    private static func decodeLength(
        _ data: Data,
        offset: inout Int,
        prefixBits: Int,
        huffmanBit: UInt8,
        expectedPattern: UInt8,
        expectedMask: UInt8
    ) throws -> (Int, Bool) {
        guard offset < data.count else { throw QPACKDecoderError.truncated }
        let first = data[offset]
        guard first & expectedMask == expectedPattern else {
            throw QPACKDecoderError.unsupportedRepresentation
        }
        let huffman = (first & huffmanBit) != 0
        let prefixMask = UInt8((1 << prefixBits) - 1)
        var value = Int(first & prefixMask)
        offset += 1
        if value == Int(prefixMask) {
            var shift = 0
            repeat {
                guard offset < data.count else { throw QPACKDecoderError.truncated }
                let byte = data[offset]
                offset += 1
                value += Int(byte & 0x7f) << shift
                shift += 7
                guard shift <= 28 else { throw QPACKDecoderError.invalidField }
                if byte & 0x80 == 0 { break }
            } while true
        }
        return (value, huffman)
    }
}
