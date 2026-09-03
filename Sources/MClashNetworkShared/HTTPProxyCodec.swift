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
    case invalidResponse
    case proxyRejected(status: Int)
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

    /// Encodes the wire request sent to an HTTP proxy node.  Credentials are
    /// deliberately passed as already-normalized values so this layer never
    /// logs or persists secrets.  CONNECT is the only supported outbound
    /// method; forwarding arbitrary HTTP requests would bypass MClash routing.
    public static func encodeConnectRequest(
        host: String,
        port: UInt16,
        username: String? = nil,
        password: String? = nil,
        extraHeaders: [String: String] = [:]
    ) throws -> Data {
        let target = try HTTPConnectRequest(host: host, port: port)
        guard (username == nil) == (password == nil) else {
            throw HTTPProxyCodecError.invalidHeader
        }
        var lines = ["CONNECT \(formatTarget(target)) HTTP/1.1", "Host: \(formatTarget(target))"]
        if let username, let password {
            let credentials = Data("\(username):\(password)".utf8).base64EncodedString()
            lines.append("Proxy-Authorization: Basic \(credentials)")
        }
        for (name, value) in extraHeaders {
            let normalized = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalized.isEmpty,
                  !normalized.contains(where: { $0 == "\r" || $0 == "\n" || $0 == ":" }),
                  !value.contains(where: { $0 == "\r" || $0 == "\n" }) else {
                throw HTTPProxyCodecError.invalidHeader
            }
            // Never allow callers to override framing or authentication.
            guard normalized.caseInsensitiveCompare("Host") != .orderedSame,
                  normalized.caseInsensitiveCompare("Proxy-Authorization") != .orderedSame else {
                throw HTTPProxyCodecError.invalidHeader
            }
            lines.append("\(normalized): \(value)")
        }
        return Data((lines.joined(separator: "\r\n") + "\r\n\r\n").utf8)
    }

    /// Validates an HTTP proxy response to CONNECT.  A response is complete
    /// only once the header terminator is present, allowing callers to use it
    /// as an incremental handshake gate before opening the intercepted flow.
    public static func decodeConnectResponse(_ data: Data) throws -> Int {
        guard data.count <= maximumHeaderBytes else { throw HTTPProxyCodecError.inputTooLarge }
        guard let end = data.range(of: Data("\r\n\r\n".utf8)) else {
            throw HTTPProxyCodecError.truncatedHeaders
        }
        guard let text = String(data: data[..<end.lowerBound], encoding: .utf8) else {
            throw HTTPProxyCodecError.invalidResponse
        }
        let lines = text.components(separatedBy: "\r\n")
        guard let status = lines.first?.split(separator: " ", omittingEmptySubsequences: true),
              status.count >= 2, status[0].hasPrefix("HTTP/"),
              let code = Int(status[1]) else {
            throw HTTPProxyCodecError.invalidResponse
        }
        guard (200 ... 299).contains(code) else {
            throw HTTPProxyCodecError.proxyRejected(status: code)
        }
        for line in lines.dropFirst() {
            guard let separator = line.firstIndex(of: ":"),
                  !line[..<separator].trimmingCharacters(in: .whitespaces).isEmpty else {
                throw HTTPProxyCodecError.invalidHeader
            }
        }
        return code
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

    private static func formatTarget(_ request: HTTPConnectRequest) -> String {
        if request.host.contains(":"), !request.host.hasPrefix("[") {
            return "[\(request.host)]:\(request.port)"
        }
        return "\(request.host):\(request.port)"
    }
}
