import Foundation
import MClashNetworkShared

/// Reader for the official v2fly GeoSiteList protobuf. Plain, RootDomain,
/// Full and Regex entries are compiled once when the database is loaded;
/// attributes remain intentionally ignored until their routing semantics are
/// modelled by MClash.
public struct NativeGeoSiteDatabaseProvider: NativeGeoDatabaseProvider {
    fileprivate struct Domain: Sendable {
        let type: UInt64
        let value: String
    }

    private final class CompiledRegex: @unchecked Sendable {
        let expression: NSRegularExpression

        init(_ pattern: String) throws {
            expression = try NSRegularExpression(
                pattern: pattern,
                options: [.caseInsensitive]
            )
        }
    }

    private enum DomainMatcher: Sendable {
        case plain(String)
        case regex(CompiledRegex)
        case root(String)
        case full(String)

        init(_ domain: Domain) throws {
            switch domain.type {
            case 0:
                let value = domain.value.lowercased()
                guard !value.isEmpty, value.utf8.count <= 253 else {
                    throw NativeGeoSiteDatabaseError.malformed
                }
                self = .plain(value)
            case 1:
                guard !domain.value.isEmpty, domain.value.utf8.count <= 2_048 else {
                    throw NativeGeoSiteDatabaseError.malformed
                }
                do {
                    self = .regex(try CompiledRegex(domain.value))
                } catch {
                    throw NativeGeoSiteDatabaseError.malformed
                }
            case 2:
                self = .root(try Self.normalizedDomain(domain.value))
            case 3:
                self = .full(try Self.normalizedDomain(domain.value))
            default:
                throw NativeGeoSiteDatabaseError.malformed
            }
        }

        func matches(_ host: String) -> Bool {
            switch self {
            case let .plain(value):
                return host.contains(value)
            case let .regex(regex):
                return regex.expression.firstMatch(
                    in: host,
                    range: NSRange(host.startIndex..., in: host)
                ) != nil
            case let .root(value):
                return host == value || host.hasSuffix("." + value)
            case let .full(value):
                return host == value
            }
        }

        private static func normalizedDomain(_ value: String) throws -> String {
            let normalized = value
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
                .trimmingCharacters(in: CharacterSet(charactersIn: "."))
            guard !normalized.isEmpty, normalized.utf8.count <= 253,
                  !normalized.contains(where: {
                      $0 == "\n" || $0 == "\r" || $0 == " " || $0 == "\t"
                  }) else {
                throw NativeGeoSiteDatabaseError.malformed
            }
            return normalized
        }
    }

    private let entries: [String: [DomainMatcher]]
    public let status: NativeGeoDatabaseStatus
    public let domainCount: Int
    public let supportedKinds: Set<NativeGeoKind> = [.site]

    public init(data: Data) throws {
        guard data.count <= 32 * 1024 * 1024 else {
            throw NativeGeoSiteDatabaseError.tooLarge
        }
        var decoder = NativeGeoSiteProtoDecoder(data: data)
        let decoded = try decoder.decode()
        var grouped: [String: [DomainMatcher]] = [:]
        var count = 0
        for (country, domains) in decoded {
            let key = country.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            guard !key.isEmpty, key.utf8.count <= 128 else {
                throw NativeGeoSiteDatabaseError.malformed
            }
            count += domains.count
            guard count <= 1_000_000 else {
                throw NativeGeoSiteDatabaseError.tooLarge
            }
            grouped[key, default: []].append(contentsOf: try domains.map(DomainMatcher.init))
        }
        guard !grouped.isEmpty else {
            throw NativeGeoSiteDatabaseError.malformed
        }
        entries = grouped
        domainCount = count
        status = .ready(revision: String(data.count))
    }

    public func matches(kind: NativeGeoKind, value: String, context: FlowContext) -> Bool {
        guard kind == .site,
              let rawHost = context.destination.hostname,
              let host = Self.normalizeHost(rawHost) else {
            return false
        }
        let category = value.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        return entries[category]?.contains { $0.matches(host) } == true
    }

    private static func normalizeHost(_ value: String) -> String? {
        let host = value.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard !host.isEmpty, host.utf8.count <= 253,
              !host.contains(where: {
                  $0 == "\n" || $0 == "\r" || $0 == " " || $0 == "\t"
              }) else {
            return nil
        }
        return host
    }
}

public enum NativeGeoSiteDatabaseError: Error, Equatable, Sendable {
    case malformed
    case tooLarge
}

private struct NativeGeoSiteProtoDecoder {
    private var cursor: NativeGeoSiteProtoCursor

    init(data: Data) {
        cursor = NativeGeoSiteProtoCursor(data: data)
    }

    mutating func decode() throws -> [(String, [NativeGeoSiteDatabaseProvider.Domain])] {
        var result: [(String, [NativeGeoSiteDatabaseProvider.Domain])] = []
        while !cursor.isAtEnd {
            let key = try cursor.varint()
            let field = Int(key >> 3)
            let wire = Int(key & 7)
            guard field != 0 else { throw NativeGeoSiteDatabaseError.malformed }
            guard field == 1 else {
                try cursor.skip(wire: wire)
                continue
            }
            guard wire == 2 else { throw NativeGeoSiteDatabaseError.malformed }
            var child = NativeGeoSiteEntryDecoder(data: try cursor.bytes())
            result.append(try child.decode())
        }
        return result
    }
}

private struct NativeGeoSiteEntryDecoder {
    private var cursor: NativeGeoSiteProtoCursor

    init(data: Data) {
        cursor = NativeGeoSiteProtoCursor(data: data)
    }

    mutating func decode() throws -> (String, [NativeGeoSiteDatabaseProvider.Domain]) {
        var country: String?
        var domains: [NativeGeoSiteDatabaseProvider.Domain] = []
        while !cursor.isAtEnd {
            let key = try cursor.varint()
            let field = Int(key >> 3)
            let wire = Int(key & 7)
            guard field != 0 else { throw NativeGeoSiteDatabaseError.malformed }
            switch field {
            case 1:
                guard wire == 2,
                      let decoded = String(data: try cursor.bytes(), encoding: .utf8) else {
                    throw NativeGeoSiteDatabaseError.malformed
                }
                country = decoded
            case 2:
                guard wire == 2 else { throw NativeGeoSiteDatabaseError.malformed }
                var domain = NativeGeoSiteDomainDecoder(data: try cursor.bytes())
                domains.append(try domain.decode())
            default:
                try cursor.skip(wire: wire)
            }
        }
        guard let country, !country.isEmpty, !domains.isEmpty else {
            throw NativeGeoSiteDatabaseError.malformed
        }
        return (country, domains)
    }
}

private struct NativeGeoSiteDomainDecoder {
    private var cursor: NativeGeoSiteProtoCursor

    init(data: Data) {
        cursor = NativeGeoSiteProtoCursor(data: data)
    }

    mutating func decode() throws -> NativeGeoSiteDatabaseProvider.Domain {
        var type: UInt64 = 0
        var value: String?
        while !cursor.isAtEnd {
            let key = try cursor.varint()
            let field = Int(key >> 3)
            let wire = Int(key & 7)
            guard field != 0 else { throw NativeGeoSiteDatabaseError.malformed }
            switch field {
            case 1:
                guard wire == 0 else { throw NativeGeoSiteDatabaseError.malformed }
                type = try cursor.varint()
            case 2:
                guard wire == 2,
                      let decoded = String(data: try cursor.bytes(), encoding: .utf8) else {
                    throw NativeGeoSiteDatabaseError.malformed
                }
                value = decoded
            default:
                try cursor.skip(wire: wire)
            }
        }
        guard let value, !value.isEmpty, type <= 3 else {
            throw NativeGeoSiteDatabaseError.malformed
        }
        return .init(type: type, value: value)
    }
}

private struct NativeGeoSiteProtoCursor {
    let data: Data
    private(set) var index = 0

    var isAtEnd: Bool { index == data.count }

    mutating func varint() throws -> UInt64 {
        var value: UInt64 = 0
        for byteIndex in 0..<10 {
            guard index < data.count else { throw NativeGeoSiteDatabaseError.malformed }
            let byte = data[index]
            index += 1
            if byteIndex == 9, byte > 1 {
                throw NativeGeoSiteDatabaseError.malformed
            }
            value |= UInt64(byte & 0x7f) << UInt64(byteIndex * 7)
            if byte & 0x80 == 0 { return value }
        }
        throw NativeGeoSiteDatabaseError.malformed
    }

    mutating func bytes() throws -> Data {
        let rawCount = try varint()
        guard rawCount <= UInt64(Int.max) else {
            throw NativeGeoSiteDatabaseError.malformed
        }
        let count = Int(rawCount)
        guard count <= data.count - index else {
            throw NativeGeoSiteDatabaseError.malformed
        }
        defer { index += count }
        return Data(data[index..<(index + count)])
    }

    mutating func skip(wire: Int) throws {
        switch wire {
        case 0:
            _ = try varint()
        case 1:
            try skipBytes(8)
        case 2:
            _ = try bytes()
        case 5:
            try skipBytes(4)
        default:
            throw NativeGeoSiteDatabaseError.malformed
        }
    }

    private mutating func skipBytes(_ count: Int) throws {
        guard count <= data.count - index else {
            throw NativeGeoSiteDatabaseError.malformed
        }
        index += count
    }
}
