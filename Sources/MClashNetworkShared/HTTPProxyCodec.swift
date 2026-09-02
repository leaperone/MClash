import Foundation

/// The HTTP CONNECT surface owned by MClash. This codec is deliberately
/// transport-free: listeners can incrementally buffer bytes, then hand one
/// complete request to the routing engine without involving Mihomo.
public struct HTTPConnectRequest: Equatable, Sendable {
    public let host: String
    public let port: UInt16
    public let headers: [String: String]

    public init(host: String, port: UInt16, headers: [String: String] = [:]) throws {
        let normalizedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedHost.isEmpty, normalizedHost.utf8.count <= 255,
              port > 0 else { throw HTTPProxyCodecError.invalidTarget }
        self.host = normalizedHost
        self.port = port
        self.headers = headers
    }
}

public enum HTTPProxyCodecError: Error, Equatable, Sendable {
    case inputTooLarge
    case truncatedHeaders
    case invalidRequestLine
    case unsupportedMethod
    case invalidTarget
    case invalidHeader
}

public enum HTTPProxyCodec: Sendable {
    public static let maximumHeaderBytes = 16 * 1024

    public static func decodeConnectRequest(_ data: Data) throws -> HTTPConnectRequest {
        guard data.count <= maximumHeaderBytes else { throw HTTPProxyCodecError.inputTooLarge }
        guard let end = data.range(of: Data("\r\n\r\n".utf8)) else {
            throw HTTPProxyCodecError.truncatedHeaders
        }
        let headerData = data[..<end.lowerBound]
        guard let text = String(data: headerData, encoding: .utf8) else {
            throw HTTPProxyCodecError.invalidHeader
        }
        let lines = text.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { throw HTTPProxyCodecError.invalidRequestLine }
        let parts = requestLine.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count == 3 else { throw HTTPProxyCodecError.invalidRequestLine }
        guard parts[0].caseInsensitiveCompare("CONNECT") == .orderedSame else {
            throw HTTPProxyCodecError.unsupportedMethod
        }
        guard parts[2].hasPrefix("HTTP/") else { throw HTTPProxyCodecError.invalidRequestLine }
        let target = try parseTarget(String(parts[1]))
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let separator = line.firstIndex(of: ":") else {
                throw HTTPProxyCodecError.invalidHeader
            }
            let name = line[..<separator].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: separator)...]
                .trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, !name.contains(where: { $0.isWhitespace }) else {
                throw HTTPProxyCodecError.invalidHeader
            }
            headers[name.lowercased()] = value
        }
        return try HTTPConnectRequest(host: target.host, port: target.port, headers: headers)
    }

    public static func encodeEstablishedResponse() -> Data {
        Data("HTTP/1.1 200 Connection Established\r\n\r\n".utf8)
    }

    public static func encodeFailureResponse(status: Int = 502, reason: String = "Bad Gateway") -> Data {
        Data("HTTP/1.1 \(status) \(reason)\r\nConnection: close\r\nContent-Length: 0\r\n\r\n".utf8)
    }

    private static func parseTarget(_ value: String) throws -> (host: String, port: UInt16) {
        if value.first == "[", let close = value.firstIndex(of: "]") {
            let host = String(value[value.index(after: value.startIndex)..<close])
            let portStart = value.index(after: close)
            guard portStart < value.endIndex, value[portStart] == ":",
                  let port = UInt16(value[value.index(after: portStart)...]) else {
                throw HTTPProxyCodecError.invalidTarget
            }
            return (host, port)
        }
        guard let separator = value.lastIndex(of: ":"),
              let port = UInt16(value[value.index(after: separator)...]) else {
            throw HTTPProxyCodecError.invalidTarget
        }
        let host = String(value[..<separator])
        guard !host.isEmpty else { throw HTTPProxyCodecError.invalidTarget }
        return (host, port)
    }
}
