import Foundation
import MClashNetworkShared

/// Reader for the official v2fly GeoSiteList protobuf. Only Plain,
/// RootDomain, Full and Regex domain entries are supported; attributes are
/// intentionally ignored until their routing semantics are modelled.
public struct NativeGeoSiteDatabaseProvider: NativeGeoDatabaseProvider {
    private struct Entry: Sendable { let domains: [Domain] }
    fileprivate struct Domain: Sendable { let type: UInt64; let value: String }
    private let entries: [String: Entry]
    public let status: NativeGeoDatabaseStatus
    public let domainCount: Int

    public init(data: Data) throws {
        guard data.count <= 32 * 1024 * 1024 else { throw NativeGeoSiteDatabaseError.tooLarge }
        var decoder = NativeGeoSiteProtoDecoder(data: data)
        let decoded = try decoder.decode()
        var grouped: [String: Entry] = [:]
        var count = 0
        for (country, domains) in decoded {
            let key = country.uppercased()
            grouped[key] = Entry(domains: domains)
            count += domains.count
        }
        guard !grouped.isEmpty else { throw NativeGeoSiteDatabaseError.malformed }
        entries = grouped
        domainCount = count
        status = .ready(revision: String(data.count))
    }

    public func matches(kind: NativeGeoKind, value: String, context: FlowContext) -> Bool {
        guard kind == .site, let host = context.destination.hostname?.lowercased() else { return false }
        return entries[value.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()]?.domains.contains {
            switch $0.type {
            case 0: host.contains($0.value.lowercased())
            case 1: (try? NSRegularExpression(pattern: $0.value, options: [.caseInsensitive]))?.firstMatch(in: host, range: NSRange(host.startIndex..., in: host)) != nil
            case 2: host == $0.value.lowercased() || host.hasSuffix("." + $0.value.lowercased())
            case 3: host == $0.value.lowercased()
            default: false
            }
        } == true
    }
}

public enum NativeGeoSiteDatabaseError: Error, Equatable, Sendable { case malformed, tooLarge }

private struct NativeGeoSiteProtoDecoder {
    let data: Data; var index = 0
    mutating func decode() throws -> [(String, [NativeGeoSiteDatabaseProvider.Domain])] {
        var result: [(String, [NativeGeoSiteDatabaseProvider.Domain])] = []
        while index < data.count {
            let key = try varint(); let field = Int(key >> 3); let wire = Int(key & 7)
            guard field == 1, wire == 2 else { try skip(wire); continue }
            var child = NativeGeoSiteEntryDecoder(data: try bytes())
            result.append(try child.decode())
        }
        return result
    }
    mutating func varint() throws -> UInt64 { var value: UInt64=0; for shift in stride(from:0,through:63,by:7) { guard index<data.count else {throw NativeGeoSiteDatabaseError.malformed}; let b=data[index]; index += 1; value |= UInt64(b&127)<<UInt64(shift); if b&128 == 0{return value} }; throw NativeGeoSiteDatabaseError.malformed }
    mutating func bytes() throws -> Data { let n=try varint(); guard n<=UInt64(data.count-index) else {throw NativeGeoSiteDatabaseError.malformed}; defer{index += Int(n)}; return Data(data[index..<index+Int(n)]) }
    mutating func skip(_ wire:Int) throws { if wire==0 {_=try varint()} else if wire==2 {_=try bytes()} else {throw NativeGeoSiteDatabaseError.malformed} }
}

private struct NativeGeoSiteEntryDecoder {
    let data: Data; var index = 0
    mutating func decode() throws -> (String, [NativeGeoSiteDatabaseProvider.Domain]) {
        var country=""; var domains:[NativeGeoSiteDatabaseProvider.Domain]=[]
        while index<data.count { let key=try varint(); let field=Int(key>>3); let wire=Int(key&7); guard field==1 || field==2 else {try skip(wire); continue}; guard wire==2 else {throw NativeGeoSiteDatabaseError.malformed}; let payload=try bytes(); if field==1 {country=String(decoding:payload,as:UTF8.self)} else { var d=NativeGeoSiteDomainDecoder(data:payload); domains.append(try d.decode()) } }
        guard !country.isEmpty, !domains.isEmpty else {throw NativeGeoSiteDatabaseError.malformed}; return (country,domains)
    }
    mutating func varint() throws -> UInt64 { var value:UInt64=0; for shift in stride(from:0,through:63,by:7){guard index<data.count else{throw NativeGeoSiteDatabaseError.malformed};let b=data[index];index+=1;value |= UInt64(b&127)<<UInt64(shift);if b&128==0{return value}};throw NativeGeoSiteDatabaseError.malformed }
    mutating func bytes() throws -> Data {let n=try varint();guard n<=UInt64(data.count-index) else{throw NativeGeoSiteDatabaseError.malformed};defer{index += Int(n)};return Data(data[index..<index+Int(n)])}
    mutating func skip(_ wire:Int)throws{if wire==0{_=try varint()}else if wire==2{_=try bytes()}else{throw NativeGeoSiteDatabaseError.malformed}}
}

private struct NativeGeoSiteDomainDecoder {
    let data: Data; var index=0
    mutating func decode() throws -> NativeGeoSiteDatabaseProvider.Domain {var type:UInt64=0;var value="";while index<data.count{let key=try varint();let field=Int(key>>3);let wire=Int(key&7);if field==1 && wire==0{type=try varint()}else if field==2 && wire==2{value=String(decoding:try bytes(),as:UTF8.self)}else{try skip(wire)}};guard !value.isEmpty,type<=3 else{throw NativeGeoSiteDatabaseError.malformed};return .init(type:type,value:value)}
    mutating func varint() throws -> UInt64 {var value:UInt64=0;for shift in stride(from:0,through:63,by:7){guard index<data.count else{throw NativeGeoSiteDatabaseError.malformed};let b=data[index];index+=1;value |= UInt64(b&127)<<UInt64(shift);if b&128==0{return value}};throw NativeGeoSiteDatabaseError.malformed}
    mutating func bytes() throws -> Data {let n=try varint();guard n<=UInt64(data.count-index) else{throw NativeGeoSiteDatabaseError.malformed};defer{index += Int(n)};return Data(data[index..<index+Int(n)])}
    mutating func skip(_ wire:Int)throws{if wire==0{_=try varint()}else if wire==2{_=try bytes()}else{throw NativeGeoSiteDatabaseError.malformed}}
}
