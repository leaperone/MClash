import Foundation
import MClashNetworkShared
import Darwin

/// Minimal reader for the official v2fly GeoIP.dat protobuf shape. It only
/// reads country code and CIDR entries; GeoSite, metadb and MaxMind formats are
/// deliberately outside this type.
public struct NativeGeoIPDatabaseProvider: NativeGeoDatabaseProvider {
    private let networksByCountry: [String: [IPNetwork]]
    public let entryCount: Int
    public let status: NativeGeoDatabaseStatus

    public init(data: Data) throws {
        guard data.count <= 32 * 1024 * 1024 else { throw NativeGeoIPDatabaseError.tooLarge }
        var decoder = NativeGeoIPProtobufDecoder(data: data)
        let decoded = try decoder.decode()
        var grouped: [String: [IPNetwork]] = [:]
        var count = 0
        for (country, networks) in decoded {
            let key = country.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            guard !key.isEmpty else { throw NativeGeoIPDatabaseError.malformed }
            grouped[key, default: []].append(contentsOf: networks)
            count += networks.count
        }
        networksByCountry = grouped
        entryCount = count
        status = .ready(revision: String(data.count))
    }

    public func matches(kind: NativeGeoKind, value: String, context: FlowContext) -> Bool {
        guard kind == .ip, let address = context.destination.ipAddress else { return false }
        let key = value.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        return networksByCountry[key]?.contains { $0.contains(address) } == true
    }
}

public enum NativeGeoIPDatabaseError: Error, Equatable, Sendable { case malformed, tooLarge }

private struct NativeGeoIPProtobufDecoder {
    let data: Data
    var index = 0
    mutating func decode() throws -> [(String, [IPNetwork])] {
        var result: [(String, [IPNetwork])] = []
        while index < data.count {
            let (field, wire) = try key()
            guard field == 1, wire == 2 else { try skip(wire); continue }
            let message = try bytes()
            var child = NativeGeoIPEntryDecoder(data: message)
            result.append(try child.decode())
        }
        return result
    }
    mutating func key() throws -> (Int, Int) {
        let value = try varint()
        return (Int(value >> 3), Int(value & 7))
    }
    mutating func varint() throws -> UInt64 {
        var value: UInt64 = 0
        for shift in stride(from: 0, through: 63, by: 7) {
            guard index < data.count else { throw NativeGeoIPDatabaseError.malformed }
            let byte = data[index]; index += 1
            value |= UInt64(byte & 0x7f) << UInt64(shift)
            if byte & 0x80 == 0 { return value }
        }
        throw NativeGeoIPDatabaseError.malformed
    }
    mutating func bytes() throws -> Data {
        let length = try varint()
        guard length <= UInt64(data.count - index) else { throw NativeGeoIPDatabaseError.malformed }
        defer { index += Int(length) }
        return Data(data[index ..< index + Int(length)])
    }
    mutating func skip(_ wire: Int) throws {
        switch wire { case 0: _ = try varint(); case 2: _ = try bytes(); default: throw NativeGeoIPDatabaseError.malformed }
    }
}

private struct NativeGeoIPEntryDecoder {
    let data: Data
    var index = 0
    mutating func decode() throws -> (String, [IPNetwork]) {
        var country = ""; var networks: [IPNetwork] = []
        while index < data.count {
            let key = try varint(); let field = Int(key >> 3); let wire = Int(key & 7)
            guard field == 1 || field == 2 else { try skip(wire); continue }
            guard wire == 2 else { throw NativeGeoIPDatabaseError.malformed }
            let payload = try bytes()
            if field == 1 { country = String(decoding: payload, as: UTF8.self) }
            else {
                var cidr = NativeGeoCIDRDecoder(data: payload)
                networks.append(try cidr.decode())
            }
        }
        guard !country.isEmpty, !networks.isEmpty else { throw NativeGeoIPDatabaseError.malformed }
        return (country, networks)
    }
    mutating func varint() throws -> UInt64 { var value: UInt64 = 0; for shift in stride(from: 0, through: 63, by: 7) { guard index < data.count else { throw NativeGeoIPDatabaseError.malformed }; let b=data[index]; index += 1; value |= UInt64(b & 127) << UInt64(shift); if b & 128 == 0 { return value } }; throw NativeGeoIPDatabaseError.malformed }
    mutating func bytes() throws -> Data { let n=try varint(); guard n <= UInt64(data.count-index) else { throw NativeGeoIPDatabaseError.malformed }; defer { index += Int(n) }; return Data(data[index..<index+Int(n)]) }
    mutating func skip(_ wire: Int) throws { if wire == 0 { _ = try varint() } else if wire == 2 { _ = try bytes() } else { throw NativeGeoIPDatabaseError.malformed } }
}

private struct NativeGeoCIDRDecoder {
    let data: Data
    var index = 0
    mutating func decode() throws -> IPNetwork {
        var address = Data(); var prefix: UInt64?
        while index < data.count { let key=try varint(); let field=Int(key>>3); let wire=Int(key&7); if field == 1 && wire == 2 { address=try bytes() } else if field == 2 && wire == 0 { prefix=try varint() } else { try skip(wire) } }
        guard address.count == 4 || address.count == 16, let prefix,
              let ip = try? IPAddress(Self.presentation(address)),
              let network = try? IPNetwork(address: ip, prefixLength: Int(prefix)) else { throw NativeGeoIPDatabaseError.malformed }
        return network
    }
    static func presentation(_ bytes: Data) -> String {
        bytes.withUnsafeBytes { raw in
            var buffer = [CChar](repeating: 0, count: Int(bytes.count == 4 ? INET_ADDRSTRLEN : INET6_ADDRSTRLEN))
            let family = bytes.count == 4 ? AF_INET : AF_INET6
            var storage = [UInt8](bytes)
            guard inet_ntop(family, &storage, &buffer, socklen_t(buffer.count)) != nil else { return "" }
            return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        }
    }
    mutating func varint() throws -> UInt64 { var value: UInt64=0; for shift in stride(from:0,through:63,by:7) { guard index<data.count else { throw NativeGeoIPDatabaseError.malformed }; let b=data[index]; index += 1; value |= UInt64(b&127)<<UInt64(shift); if b&128 == 0{return value} }; throw NativeGeoIPDatabaseError.malformed }
    mutating func bytes() throws -> Data { let n=try varint(); guard n<=UInt64(data.count-index) else { throw NativeGeoIPDatabaseError.malformed }; defer{index += Int(n)}; return Data(data[index..<index+Int(n)]) }
    mutating func skip(_ wire:Int) throws { if wire==0 {_=try varint()} else if wire==2 {_=try bytes()} else {throw NativeGeoIPDatabaseError.malformed} }
}
