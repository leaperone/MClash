import Foundation

public enum QPACKEncoderError: Error, Equatable, Sendable {
    case fieldTooLong
    case invalidFieldName
    case invalidFieldValue
}

/// Minimal QPACK field-section encoder using literal names/values only. It
/// deliberately avoids the dynamic table and Huffman coding so Hysteria2
/// control streams remain deterministic and cannot block on encoder state.
public enum QPACKEncoder: Sendable {
    public static func encodeLiteralFields(_ fields: [(String, String)]) throws -> Data {
        var result = Data([0x00, 0x00]) // Required Insert Count, Delta Base
        for (name, value) in fields {
            let nameBytes = Array(name.utf8)
            let valueBytes = Array(value.utf8)
            guard !nameBytes.isEmpty, nameBytes.count <= 255 else { throw QPACKEncoderError.invalidFieldName }
            guard valueBytes.count <= 65_535 else { throw QPACKEncoderError.invalidFieldValue }
            result.append(try encodeStringLiteral(nameBytes, prefixBits: 4, prefixPattern: 0x20))
            result.append(try encodeStringLiteral(valueBytes, prefixBits: 7, prefixPattern: 0x00))
        }
        return result
    }

    private static func encodeStringLiteral(
        _ bytes: [UInt8],
        prefixBits: Int,
        prefixPattern: UInt8
    ) throws -> Data {
        guard bytes.count < (1 << 30) else { throw QPACKEncoderError.fieldTooLong }
        var output = Data()
        let maxPrefix = (1 << prefixBits) - 1
        if bytes.count < maxPrefix {
            output.append(prefixPattern | UInt8(bytes.count))
        } else {
            output.append(prefixPattern | UInt8(maxPrefix))
            var remainder = bytes.count - maxPrefix
            while remainder >= 128 {
                output.append(UInt8(remainder & 0x7f) | 0x80)
                remainder >>= 7
            }
            output.append(UInt8(remainder))
        }
        output.append(contentsOf: bytes)
        return output
    }
}
