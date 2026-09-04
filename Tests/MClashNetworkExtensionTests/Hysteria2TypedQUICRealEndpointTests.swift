import Foundation
import Testing
@testable import MClashNetworkExtension
import MClashNetworkShared

/// Opt-in only.  This never starts an entrance or changes the installed
/// Network Extension; it opens a temporary typed QUIC session directly.
@Suite("Hysteria2 typed QUIC real endpoint", .serialized)
struct Hysteria2TypedQUICRealEndpointTests {
    @Test("Authenticates, opens an independent TCP stream, and gets HTTP 204")
    func realProfileGenerate204() async throws {
        guard #available(macOS 26.0, *),
              let path = ProcessInfo.processInfo.environment["MCLASH_REAL_PROFILE_MANIFEST"] else { return }
        let hint = ProcessInfo.processInfo.environment["MCLASH_REAL_NODE_NAME_CONTAINS"] ?? "🇸🇬 新加坡11aws"
        let target = try Self.loadTarget(path: path, hint: hint)
        let provider = NativeHysteria2QUICProvider(connector: NativeHysteria2OutboundConnector(target: target))
        defer { Task { await provider.close() } }
        #expect(try await provider.authenticate())
        let stream = try await provider.openBidirectionalStream()
        let destination = try SOCKS5Endpoint(address: SOCKS5Address(domain: "www.google.com"), port: 80)
        try await stream.send(try Hysteria2Codec.encodeTCPRequest(host: "www.google.com", port: 80))
        var responseDecoder = Hysteria2TCPResponseDecoder()
        for _ in 0..<32 {
            guard let data = try await stream.receive() else { throw ProbeError.eof("TCP response") }
            if try responseDecoder.append(data) != nil { break }
        }
        let request = Data("GET /generate_204 HTTP/1.1\r\nHost: www.google.com\r\nConnection: close\r\n\r\n".utf8)
        try await stream.send(request)
        var http = Data()
        for _ in 0..<64 {
            guard let data = try await stream.receive() else { break }
            http.append(data)
            if http.range(of: Data("\r\n\r\n".utf8)) != nil { break }
        }
        let status = String(decoding: http, as: UTF8.self).split(separator: "\r\n", maxSplits: 1).first ?? ""
        #expect(status.hasPrefix("HTTP/1.1 204") || status.hasPrefix("HTTP/2 204"))
        _ = destination
        await stream.close()
    }

    private static func loadTarget(path: String, hint: String) throws -> OutboundNodeTarget {
        let data = try Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe)
        guard data.count <= 32 * 1024 * 1024,
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let nodes = root["nodes"] as? [[String: Any]] else { throw ProbeError.invalidManifest }
        for node in nodes where (node["displayName"] as? String)?.localizedCaseInsensitiveContains(hint) == true {
            guard node["proto"] as? String == "hysteria2",
                  let host = node["host"] as? String,
                  let number = node["port"] as? NSNumber,
                  let port = UInt16(exactly: number.intValue),
                  let raw = node["parameters"] as? [String: Any] else { continue }
            let parameters = raw.reduce(into: [String: String]()) { result, pair in
                if let value = pair.value as? String { result[pair.key] = value }
            }
            return try OutboundNodeTarget(protocolName: "hysteria2", host: host, port: port, parameters: parameters)
        }
        throw ProbeError.nodeNotFound
    }
}

private enum ProbeError: Error { case invalidManifest, nodeNotFound, eof(String) }
