import Foundation

/// The transport options preserved by the node-only importer for a VLESS
/// WebSocket node.  This is deliberately a value type in the shared target so
/// both the compiler and a future native connector consume the same parsed
/// representation rather than each interpreting an opaque JSON string.
public struct VLESSWebSocketOptions: Codable, Equatable, Hashable, Sendable {
    public let path: String
    public let headers: [String: String]

    public init(path: String = "/", headers: [String: String] = [:]) {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        self.path = trimmed.isEmpty ? "/" : (trimmed.hasPrefix("/") ? trimmed : "/" + trimmed)
        self.headers = headers
    }

    /// Reads the common Clash spellings (`ws-opts`, `ws_opts`, and flattened
    /// `ws-path`/`ws-host`). Importers currently store nested maps as JSON in
    /// `OutboundNodeTarget.parameters`, so malformed JSON is rejected instead
    /// of silently selecting a different transport.
    public static func parse(parameters: [String: String]) -> VLESSWebSocketOptions? {
        let normalized = Dictionary(parameters.map {
            ($0.key.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                .replacingOccurrences(of: "_", with: "-"), $0.value)
        }, uniquingKeysWith: { first, _ in first })
        var path: String?
        var headers: [String: String] = [:]
        for key in ["ws-opts", "ws-options"] {
            guard let raw = normalized[key],
                  let data = raw.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data),
                  let map = object as? [String: Any]
            else { continue }
            if let value = map["path"] as? String { path = value }
            if let values = map["headers"] as? [String: String] { headers.merge(values) { _, new in new } }
            if let values = map["headers"] as? [String: Any] {
                for (name, value) in values {
                    if let value = value as? String { headers[name] = value }
                }
            }
        }
        path = path ?? normalized["ws-path"]
        if let host = normalized["ws-host"], !host.isEmpty { headers["Host"] = host }
        guard path != nil || !headers.isEmpty || normalized.keys.contains("ws-opts") || normalized.keys.contains("ws-options") else {
            return nil
        }
        return VLESSWebSocketOptions(path: path ?? "/", headers: headers)
    }
}

public enum VLESSWebSocketTransportDiagnostic: Equatable, Sendable {
    case nativeTransportUnavailable(path: String)

    public var message: String {
        switch self {
        case let .nativeTransportUnavailable(path):
            return "VLESS WebSocket transport requires a two-phase HTTP upgrade on path \(path)."
        }
    }
}
