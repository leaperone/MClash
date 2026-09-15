import Foundation

public struct NodeLinkImportRequest: Sendable {
    public let sourceID: SourceID
    public let text: String
    public let now: Date
    public init(sourceID: SourceID = SourceID(), text: String, now: Date = Date()) { self.sourceID = sourceID; self.text = text; self.now = now }
}

public struct NodeLinkImportPreview: Sendable {
    public let nodes: [Node]
    public let diagnostics: [ConfigurationDiagnostic]
    public let ignoredLines: Int
    public let detectedFormats: [String]
    public init(nodes: [Node], diagnostics: [ConfigurationDiagnostic], ignoredLines: Int, detectedFormats: [String]) { self.nodes = nodes; self.diagnostics = diagnostics; self.ignoredLines = ignoredLines; self.detectedFormats = detectedFormats }
}

public struct NodeLinkImporter: Sendable {
    private static let limit = 256 * 1024
    private static let schemes = Set(["vless", "vmess", "trojan", "ss", "http", "socks5"])
    public init() {}

    public func preview(_ request: NodeLinkImportRequest) -> NodeLinkImportPreview {
        guard request.text.utf8.count <= Self.limit else { return .init(nodes: [], diagnostics: [diagnostic("input_too_large", "Input is too large to preview.")], ignoredLines: 0, detectedFormats: []) }
        var nodes: [Node] = [], diagnostics: [ConfigurationDiagnostic] = [], seen = Set<String>(), formats = Set<String>(), ignored = 0
        for (index, raw) in request.text.split(whereSeparator: \.isNewline).map(String.init).enumerated() {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            guard let scheme = line.split(separator: ":", maxSplits: 1).first.map({ $0.lowercased() }), Self.schemes.contains(scheme) else { ignored += 1; diagnostics.append(diagnostic("unsupported_scheme", "Line \(index + 1) uses an unsupported link format.")); continue }
            formats.insert(scheme)
            do {
                let candidate = try parse(line, scheme: scheme)
                let node = try Node(id: NodeID.stable(for: candidate.proto.rawValue + "|" + candidate.host.lowercased() + "|\(candidate.port)|" + candidate.parameters.sorted(by: { $0.key < $1.key }).map { "\($0.key)=\($0.value)" }.joined(separator: "&")), displayName: candidate.name, protocol: candidate.proto, host: candidate.host, port: candidate.port, parameters: candidate.parameters, sourceLinks: [request.sourceID], lastSeenAt: request.now)
                guard seen.insert(node.connectionFingerprint).inserted else { diagnostics.append(diagnostic("duplicate_link", "Line \(index + 1) duplicates an imported node.")); continue }
                nodes.append(node)
            } catch { diagnostics.append(diagnostic("invalid_link", "Line \(index + 1) is not a valid proxy link.")) }
        }
        return .init(nodes: nodes, diagnostics: diagnostics, ignoredLines: ignored, detectedFormats: formats.sorted())
    }

    private struct Candidate { let proto: NodeProtocol; let host: String; let port: Int; let name: String; let parameters: [String: String] }
    private func parse(_ value: String, scheme: String) throws -> Candidate {
        if scheme == "vmess" { return try parseVmess(value) }
        guard let url = URL(string: value), let host = url.host, let port = url.port else { throw NSError(domain: "NodeLink", code: 1) }
        let proto: NodeProtocol = scheme == "ss" ? .shadowsocks : (scheme == "socks5" ? .socks5 : NodeProtocol(rawValue: scheme)!)
        var params: [String: String] = [:]
        if let user = url.user { params["username"] = user.removingPercentEncoding ?? user }
        if let password = url.password { params["password"] = password.removingPercentEncoding ?? password }
        if let hostName = url.fragment?.removingPercentEncoding, !hostName.isEmpty { params["name"] = hostName }
        if let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems { for item in query where item.value != nil { params[item.name] = item.value! } }
        if scheme == "ss", let user = url.user, let decoded = decodeBase64(user), let colon = decoded.firstIndex(of: ":") { params["method"] = String(decoded[..<colon]); params["password"] = String(decoded[decoded.index(after: colon)...]) }
        return Candidate(proto: proto, host: host, port: port, name: params["name"] ?? host, parameters: params)
    }
    private func parseVmess(_ value: String) throws -> Candidate {
        guard let payload = decodeBase64(String(value.dropFirst(8))), let object = try JSONSerialization.jsonObject(with: payload) as? [String: Any], let host = object["add"] as? String, let port = Int(String(describing: object["port"] ?? "")), port > 0 else { throw NSError(domain: "NodeLink", code: 2) }
        var p = object.compactMapValues { String(describing: $0) }; p.removeValue(forKey: "add"); p.removeValue(forKey: "port"); let name = p.removeValue(forKey: "ps") ?? host
        return Candidate(proto: .vmess, host: host, port: port, name: name, parameters: p)
    }
    private func decodeBase64(_ input: String) -> Data? { var s = input.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/"); s += String(repeating: "=", count: (4 - s.count % 4) % 4); return Data(base64Encoded: s) }
    private func diagnostic(_ code: String, _ message: String) -> ConfigurationDiagnostic { .init(severity: .warning, code: code, subject: "node-link", message: message) }
}
