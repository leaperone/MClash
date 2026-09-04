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
        let hint = ProcessInfo.processInfo.environment["MCLASH_REAL_NODE_NAME_CONTAINS"] ?? "新加坡11aws"
        let target = try Self.loadTarget(path: path, hint: hint)
        let provider = NativeHysteria2QUICProvider(connector: NativeHysteria2OutboundConnector(target: target))
        defer { Task { await provider.close() } }
        try await Self.withTimeout(stage: "QUIC connection", provider: provider) {
            try await provider.prepareConnection()
        }
        #expect(try await Self.withTimeout(stage: "authentication", provider: provider) {
            try await provider.authenticate()
        })
        let stream = try await Self.withTimeout(stage: "open TCP stream", provider: provider) {
            try await provider.openBidirectionalStream()
        }
        let destination = try SOCKS5Endpoint(address: SOCKS5Address(domain: "www.google.com"), port: 80)
        try await stream.send(try Hysteria2Codec.encodeTCPRequest(host: "www.google.com", port: 80))
        var responseDecoder = Hysteria2TCPResponseDecoder()
        for _ in 0..<32 {
            guard let data = try await Self.withTimeout(
                stage: "TCP response",
                provider: provider,
                operation: { try await stream.receive() }
            ) else { throw ProbeError.eof("TCP response") }
            if try responseDecoder.append(data) != nil { break }
        }
        let request = Data("GET /generate_204 HTTP/1.1\r\nHost: www.google.com\r\nConnection: close\r\n\r\n".utf8)
        try await stream.send(request)
        var http = Data()
        for _ in 0..<64 {
            guard let data = try await Self.withTimeout(
                stage: "HTTP response",
                provider: provider,
                operation: { try await stream.receive() }
            ) else { break }
            http.append(data)
            if http.range(of: Data("\r\n\r\n".utf8)) != nil { break }
        }
        let status = String(decoding: http, as: UTF8.self).split(separator: "\r\n", maxSplits: 1).first ?? ""
        #expect(status.hasPrefix("HTTP/1.1 204") || status.hasPrefix("HTTP/2 204"))
        _ = destination
        await stream.close()
    }

    @available(macOS 26.0, *)
    private static func withTimeout<Value: Sendable>(
        stage: String,
        provider: NativeHysteria2QUICProvider,
        operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        try await withCheckedThrowingContinuation { continuation in
            let gate = Hysteria2ProbeResultGate(continuation)
            let operationTask = Task {
                do {
                    _ = gate.resolve(.success(try await operation()))
                } catch {
                    _ = gate.resolve(.failure(error))
                }
            }
            Task {
                try? await Task.sleep(for: .seconds(15))
                if gate.resolve(.failure(ProbeError.timeout(stage))) {
                    operationTask.cancel()
                    await provider.close()
                }
            }
        }
    }

    private static func loadTarget(path: String, hint: String) throws -> OutboundNodeTarget {
        let data = try Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe)
        guard data.count <= 32 * 1024 * 1024,
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let nodes = root["nodes"] as? [[String: Any]] else { throw ProbeError.invalidManifest }
        for node in nodes where (node["displayName"] as? String)?.localizedCaseInsensitiveContains(hint) == true {
            let availability = (node["health"] as? [String: Any])?["availability"] as? String
            guard node["enabled"] as? Bool != false,
                  availability != "sourceRemoved",
                  availability != "unsupported",
                  node["proto"] as? String == "hysteria2",
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

private enum ProbeError: Error {
    case invalidManifest
    case nodeNotFound
    case eof(String)
    case timeout(String)
}

private final class Hysteria2ProbeResultGate<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, any Error>?

    init(_ continuation: CheckedContinuation<Value, any Error>) {
        self.continuation = continuation
    }

    @discardableResult
    func resolve(_ result: Result<Value, any Error>) -> Bool {
        lock.lock()
        guard let continuation else {
            lock.unlock()
            return false
        }
        self.continuation = nil
        lock.unlock()
        continuation.resume(with: result)
        return true
    }
}
