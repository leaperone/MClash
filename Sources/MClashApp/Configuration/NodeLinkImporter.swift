import Foundation

public struct NodeLinkImportRequest: Sendable {
    public let sourceID: SourceID
    public let text: String
    public let now: Date

    public init(sourceID: SourceID = SourceID(), text: String, now: Date = Date()) {
        self.sourceID = sourceID
        self.text = text
        self.now = now
    }
}

public struct NodeLinkImportPreview: Sendable {
    public let nodes: [Node]
    public let diagnostics: [ConfigurationDiagnostic]
    public let ignoredLines: Int
    public let detectedFormats: [String]

    public init(nodes: [Node], diagnostics: [ConfigurationDiagnostic], ignoredLines: Int, detectedFormats: [String]) {
        self.nodes = nodes
        self.diagnostics = diagnostics
        self.ignoredLines = ignoredLines
        self.detectedFormats = detectedFormats
    }
}

public struct NodeLinkImporter: Sendable {
    private static let inputLimit = 256 * 1024
    private static let supportedSchemes = Set(["vless", "vmess", "trojan", "ss", "http", "socks5", "hysteria2", "hy2"])

    public init() {}

    public func preview(_ request: NodeLinkImportRequest) -> NodeLinkImportPreview {
        guard request.text.utf8.count <= Self.inputLimit else {
            return .init(nodes: [], diagnostics: [diagnostic("input_too_large", "The pasted text is too large to read.")], ignoredLines: 0, detectedFormats: [])
        }
        var nodes: [Node] = []
        var diagnostics: [ConfigurationDiagnostic] = []
        var seen = Set<String>()
        var formats = Set<String>()
        var ignoredLines = 0
        for (lineIndex, raw) in request.text.split(whereSeparator: \.isNewline).map(String.init).enumerated() {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            let scheme = line.split(separator: ":", maxSplits: 1).first.map(String.init)?.lowercased()
            guard let scheme, Self.supportedSchemes.contains(scheme) else {
                ignoredLines += 1
                diagnostics.append(diagnostic("unsupported_scheme", "Line \(lineIndex + 1) uses an unsupported link format."))
                continue
            }
            formats.insert(scheme == "hy2" ? "hysteria2" : scheme)
            do {
                let candidate = try parse(line, scheme: scheme)
                let node = try Node(id: NodeID.stable(for: candidate.identity), displayName: candidate.name,
                    protocol: candidate.proto, host: candidate.host, port: candidate.port,
                    parameters: candidate.parameters, sourceLinks: [request.sourceID], lastSeenAt: request.now)
                guard seen.insert(node.connectionFingerprint).inserted else {
                    diagnostics.append(diagnostic("duplicate_link", "Line \(lineIndex + 1) repeats an imported node."))
                    continue
                }
                nodes.append(node)
            } catch {
                diagnostics.append(diagnostic("invalid_link", "Line \(lineIndex + 1) is not a valid proxy link."))
            }
        }
        return .init(nodes: nodes, diagnostics: diagnostics, ignoredLines: ignoredLines, detectedFormats: formats.sorted())
    }

    private struct Candidate {
        let proto: NodeProtocol
        let host: String
        let port: Int
        let name: String
        let parameters: [String: String]
        var identity: String { Node.makeConnectionFingerprint(protocol: proto, host: host, port: port, parameters: parameters) }
    }

    private func parse(_ value: String, scheme: String) throws -> Candidate {
        if scheme == "vmess" { return try parseVmess(value) }
        if scheme == "ss" { return try parseShadowsocks(value) }
        guard let url = URL(string: value), let host = url.host, let port = url.port, (1...65_535).contains(port) else { throw ImportError.invalid }
        var parameters = queryParameters(url)
        let name = decoded(url.fragment) ?? host
        let proto: NodeProtocol
        switch scheme {
        case "vless":
            guard let uuid = decoded(url.user), UUID(uuidString: uuid) != nil else { throw ImportError.invalid }
            parameters["uuid"] = uuid
            if let short = parameters.removeValue(forKey: "sid") { parameters["reality-opts.short-id"] = short }
            if let publicKey = parameters.removeValue(forKey: "pbk") { parameters["reality-public-key"] = publicKey }
            if let path = parameters.removeValue(forKey: "path") { parameters["ws-opts.path"] = path }
            normalizeTransportParameters(&parameters)
            proto = .vless
        case "trojan":
            guard let password = decoded(url.user), !password.isEmpty else { throw ImportError.invalid }
            parameters["password"] = password
            normalizeTransportParameters(&parameters)
            proto = .trojan
        case "hysteria2", "hy2":
            guard let password = decoded(url.user), !password.isEmpty else { throw ImportError.invalid }
            parameters["password"] = password
            if let sni = parameters.removeValue(forKey: "sni") { parameters["servername"] = sni }
            proto = .hysteria2
        case "http", "socks5":
            if let user = decoded(url.user) { parameters["username"] = user }
            if let password = decoded(url.password) { parameters["password"] = password }
            proto = scheme == "http" ? .http : .socks5
        default: throw ImportError.invalid
        }
        return Candidate(proto: proto, host: host, port: port, name: name, parameters: parameters)
    }

    private func parseVmess(_ value: String) throws -> Candidate {
        guard let data = decodeBase64(String(value.dropFirst("vmess://".count))),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let host = object["add"] as? String,
              let port = Int(String(describing: object["port"] ?? "")), (1...65_535).contains(port),
              let uuid = object["id"] as? String, UUID(uuidString: uuid) != nil else { throw ImportError.invalid }
        var parameters: [String: String] = ["uuid": uuid]
        if let network = stringValue(object["net"]) { parameters["network"] = network }
        if let tls = stringValue(object["tls"]), !tls.isEmpty { parameters["tls"] = tls == "tls" || tls == "true" ? "true" : "false" }
        if let sni = stringValue(object["sni"]), !sni.isEmpty { parameters["servername"] = sni }
        if let hostHeader = stringValue(object["host"]), !hostHeader.isEmpty { parameters["host"] = hostHeader }
        if let path = stringValue(object["path"]), !path.isEmpty { parameters["ws-opts.path"] = path }
        if let cipher = stringValue(object["scy"]), !cipher.isEmpty { parameters["cipher"] = cipher }
        return Candidate(proto: .vmess, host: host, port: port, name: stringValue(object["ps"]) ?? host, parameters: parameters)
    }

    private func parseShadowsocks(_ value: String) throws -> Candidate {
        let payload = String(value.dropFirst("ss://".count))
        let parts = payload.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
        let withoutName = String(parts[0])
        let name = decoded(parts.count == 2 ? String(parts[1]) : nil)
        if let url = URL(string: "ss://" + withoutName), let host = url.host, let port = url.port,
           let encodedUser = url.user, let data = decodeBase64(encodedUser),
           let methodPassword = String(data: data, encoding: .utf8) {
            return try shadowsocksCandidate(methodPassword: methodPassword, host: host, port: port, name: name ?? host)
        }
        guard let data = decodeBase64(withoutName), let text = String(data: data, encoding: .utf8),
              let separator = text.firstIndex(of: "@") else { throw ImportError.invalid }
        let methodPassword = String(text[..<separator])
        let endpoint = String(text[text.index(after: separator)...])
        guard let url = URL(string: "ss://" + endpoint), let host = url.host, let port = url.port else { throw ImportError.invalid }
        return try shadowsocksCandidate(methodPassword: methodPassword, host: host, port: port, name: name ?? host)
    }

    private func shadowsocksCandidate(methodPassword: String, host: String, port: Int, name: String) throws -> Candidate {
        let parts = methodPassword.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { throw ImportError.invalid }
        return Candidate(proto: .shadowsocks, host: host, port: port, name: name,
            parameters: ["cipher": parts[0], "password": parts[1]])
    }

    private func queryParameters(_ url: URL) -> [String: String] {
        var result: [String: String] = [:]
        for item in URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [] {
            guard let value = item.value else { continue }
            result[item.name.lowercased()] = value
        }
        return result
    }

    private func normalizeTransportParameters(_ values: inout [String: String]) {
        if let type = values.removeValue(forKey: "type") { values["network"] = type }
        if let security = values.removeValue(forKey: "security") { values["tls"] = security == "tls" || security == "reality" ? "true" : "false" }
        if let sni = values.removeValue(forKey: "sni") { values["servername"] = sni }
        if let fp = values.removeValue(forKey: "fp") { values["client-fingerprint"] = fp }
        if let allow = values.removeValue(forKey: "allowinsecure") { values["skip-cert-verify"] = allow }
    }

    private func decoded(_ value: String?) -> String? { value?.removingPercentEncoding ?? value }
    private func stringValue(_ value: Any?) -> String? { (value as? String) ?? value.map { String(describing: $0) } }
    private func decodeBase64(_ value: String) -> Data? {
        var input = value.removingPercentEncoding ?? value
        input = input.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        input += String(repeating: "=", count: (4 - input.count % 4) % 4)
        return Data(base64Encoded: input)
    }
    private func diagnostic(_ code: String, _ message: String) -> ConfigurationDiagnostic {
        .init(severity: .warning, code: code, subject: "node-link", message: message)
    }
    private enum ImportError: Error { case invalid }
}
