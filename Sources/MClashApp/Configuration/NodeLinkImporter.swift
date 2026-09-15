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
    private static let supportedSchemes = Set(["vless", "vmess", "trojan", "ss", "http", "socks", "socks5", "hysteria2", "hy2", "wireguard"])

    public init() {}

    public func preview(_ request: NodeLinkImportRequest) -> NodeLinkImportPreview {
        guard request.text.utf8.count <= Self.inputLimit else {
            return .init(nodes: [], diagnostics: [diagnostic("input_too_large", "The pasted text is too large to read.", subject: "input")], ignoredLines: 0, detectedFormats: [])
        }
        if Self.looksLikeWireGuardConfiguration(request.text) {
            return previewWireGuardConfiguration(request)
        }
        let plain = parseLines(request.text, sourceID: request.sourceID, now: request.now)
        guard plain.nodes.isEmpty, let decoded = decodeEncodedNodeList(request.text),
              containsSupportedLink(in: decoded) else {
            return plain.preview
        }
        let encoded = parseLines(decoded, sourceID: request.sourceID, now: request.now)
        return .init(
            nodes: encoded.nodes,
            diagnostics: encoded.diagnostics,
            ignoredLines: encoded.ignoredLines,
            detectedFormats: encoded.detectedFormats + ["encoded-links"]
        )
    }

    private struct ParsedLines: Sendable {
        let nodes: [Node]
        let diagnostics: [ConfigurationDiagnostic]
        let ignoredLines: Int
        let detectedFormats: [String]

        var preview: NodeLinkImportPreview {
            .init(nodes: nodes, diagnostics: diagnostics, ignoredLines: ignoredLines, detectedFormats: detectedFormats)
        }
    }

    private func parseLines(_ text: String, sourceID: SourceID, now: Date) -> ParsedLines {
        var nodes: [Node] = []
        var diagnostics: [ConfigurationDiagnostic] = []
        var seen = Set<String>()
        var formats = Set<String>()
        var ignoredLines = 0
        for (lineIndex, raw) in text.split(whereSeparator: \.isNewline).map(String.init).enumerated() {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            let scheme = line.split(separator: ":", maxSplits: 1).first.map(String.init)?.lowercased()
            guard let scheme, Self.supportedSchemes.contains(scheme) else {
                ignoredLines += 1
                diagnostics.append(diagnostic("unsupported_scheme", "Line \(lineIndex + 1) uses an unsupported link format.", subject: "line-\(lineIndex + 1)"))
                continue
            }
            formats.insert(Self.detectedFormat(for: scheme))
            do {
                let candidate = try parse(line, scheme: scheme)
                let node = try Node(id: NodeID.stable(for: candidate.identity), displayName: candidate.name,
                    protocol: candidate.proto, host: candidate.host, port: candidate.port,
                    parameters: candidate.parameters, sourceLinks: [sourceID], lastSeenAt: now)
                guard seen.insert(node.connectionFingerprint).inserted else {
                    diagnostics.append(diagnostic("duplicate_link", "Line \(lineIndex + 1) repeats an imported node.", subject: "line-\(lineIndex + 1)"))
                    continue
                }
                nodes.append(node)
            } catch {
                diagnostics.append(diagnostic("invalid_link", "Line \(lineIndex + 1) is not a valid proxy link.", subject: "line-\(lineIndex + 1)"))
            }
        }
        return ParsedLines(nodes: nodes, diagnostics: diagnostics, ignoredLines: ignoredLines, detectedFormats: formats.sorted())
    }

    private func decodeEncodedNodeList(_ text: String) -> String? {
        let compact = text.filter { !$0.isWhitespace }
        guard compact.count >= 8, compact.utf8.count <= Self.inputLimit,
              compact.allSatisfy({ $0.isASCII && $0.isLetter || $0.isNumber || "+/_=-".contains($0) }) else {
            return nil
        }
        var normalized = compact.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        normalized += String(repeating: "=", count: (4 - normalized.count % 4) % 4)
        guard let data = Data(base64Encoded: normalized),
              data.count <= Self.inputLimit,
              let decoded = String(data: data, encoding: .utf8) else {
            return nil
        }
        return decoded
    }

    private func containsSupportedLink(in text: String) -> Bool {
        text.split(whereSeparator: \.isNewline).contains { raw in
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let scheme = line.split(separator: ":", maxSplits: 1).first.map(String.init)?.lowercased() else {
                return false
            }
            return Self.supportedSchemes.contains(scheme)
        }
    }

    private static func looksLikeWireGuardConfiguration(_ text: String) -> Bool {
        let sections = text.split(whereSeparator: \.isNewline).compactMap { raw -> String? in
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard line.hasPrefix("[") && line.hasSuffix("]") else { return nil }
            return line.dropFirst().dropLast().trimmingCharacters(in: .whitespaces).lowercased()
        }
        return sections.contains("interface") && sections.contains("peer")
    }

    private func previewWireGuardConfiguration(_ request: NodeLinkImportRequest) -> NodeLinkImportPreview {
        do {
            let candidates = try parseWireGuardConfiguration(request.text)
            var seen = Set<String>()
            var nodes: [Node] = []
            var diagnostics: [ConfigurationDiagnostic] = []
            for (index, candidate) in candidates.enumerated() {
                let node = try Node(
                    id: NodeID.stable(for: candidate.identity),
                    displayName: candidate.name,
                    protocol: candidate.proto,
                    host: candidate.host,
                    port: candidate.port,
                    parameters: candidate.parameters,
                    sourceLinks: [request.sourceID],
                    lastSeenAt: request.now
                )
                guard seen.insert(node.connectionFingerprint).inserted else {
                    diagnostics.append(diagnostic("duplicate_wireguard_peer", "Peer \(index + 1) repeats an imported endpoint.", subject: "peer-\(index + 1)"))
                    continue
                }
                nodes.append(node)
            }
            return .init(nodes: nodes, diagnostics: diagnostics, ignoredLines: 0, detectedFormats: ["wireguard-config"])
        } catch let error as ImportError {
            return .init(nodes: [], diagnostics: [diagnostic("invalid_wireguard_config", error.message, subject: error.subject)], ignoredLines: 0, detectedFormats: ["wireguard-config"])
        } catch {
            return .init(nodes: [], diagnostics: [diagnostic("invalid_wireguard_config", "The WireGuard configuration could not be read.", subject: "wireguard")], ignoredLines: 0, detectedFormats: ["wireguard-config"])
        }
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
        case "wireguard":
            guard let secretKey = decoded(url.user), !secretKey.isEmpty,
                  let publicKey = firstQueryValue(parameters, keys: ["publickey", "public-key", "peer-public-key"]),
                  !publicKey.isEmpty else { throw ImportError.invalid }
            parameters["secret-key"] = secretKey
            parameters["public-key"] = publicKey
            if let address = firstQueryValue(parameters, keys: ["address", "addresses"]), !address.isEmpty {
                parameters["address"] = address
            }
            if let allowed = firstQueryValue(parameters, keys: ["allowedips", "allowed-ips"]) {
                parameters["allowed-ips"] = allowed
            }
            if let psk = firstQueryValue(parameters, keys: ["psk", "presharedkey", "pre-shared-key"]) {
                parameters["pre-shared-key"] = psk
            }
            if let keepAlive = firstQueryValue(parameters, keys: ["keepalive", "keep-alive"]) {
                parameters["keep-alive"] = keepAlive
            }
            if let domainStrategy = firstQueryValue(parameters, keys: ["domainstrategy", "domain-strategy"]) {
                parameters["domain-strategy"] = domainStrategy
            }
            if let dns = firstQueryValue(parameters, keys: ["dns", "remote-dns"]) {
                parameters["remote-dns"] = dns
            }
            proto = .wireguard
        case "http", "socks", "socks5":
            if let user = decoded(url.user) { parameters["username"] = user }
            if let password = decoded(url.password) { parameters["password"] = password }
            proto = scheme == "http" ? .http : .socks5
        default: throw ImportError.invalid
        }
        return Candidate(proto: proto, host: host, port: port, name: name, parameters: parameters)
    }

    private func parseWireGuardConfiguration(_ text: String) throws -> [Candidate] {
        enum Section { case none, interface, peer }
        var section: Section = .none
        var interface: [String: String] = [:]
        var peers: [[String: String]] = []
        var currentPeer: [String: String]?

        for (lineNumber, raw) in text.split(whereSeparator: \.isNewline).map(String.init).enumerated() {
            let withoutHashComment = raw.split(separator: "#", maxSplits: 1).first.map(String.init) ?? raw
            let withoutComment = withoutHashComment.split(separator: ";", maxSplits: 1).first.map(String.init) ?? withoutHashComment
            let line = withoutComment.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty { continue }
            if line.hasPrefix("[") && line.hasSuffix("]") {
                if case .peer = section, let currentPeer { peers.append(currentPeer) }
                currentPeer = nil
                switch line.dropFirst().dropLast().trimmingCharacters(in: .whitespaces).lowercased() {
                case "interface": section = .interface
                case "peer": section = .peer
                default: throw ImportError.wireGuard("Line \(lineNumber + 1): unknown section.", subject: "line-\(lineNumber + 1)")
                }
                continue
            }
            guard let equals = line.firstIndex(of: "=") else {
                throw ImportError.wireGuard("Line \(lineNumber + 1): expected Key = Value.", subject: "line-\(lineNumber + 1)")
            }
            let key = line[..<equals].trimmingCharacters(in: .whitespacesAndNewlines).lowercased().replacingOccurrences(of: "_", with: "-")
            let value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty, !value.isEmpty else {
                throw ImportError.wireGuard("Line \(lineNumber + 1): key and value are required.", subject: "line-\(lineNumber + 1)")
            }
            switch section {
            case .interface: interface[key] = value
            case .peer:
                if currentPeer == nil { currentPeer = [:] }
                currentPeer?[key] = value
            case .none:
                throw ImportError.wireGuard("Line \(lineNumber + 1): key appears before a section.", subject: "line-\(lineNumber + 1)")
            }
        }
        if case .peer = section, let currentPeer { peers.append(currentPeer) }
        guard let secretKey = interface["privatekey"], validWireGuardKey(secretKey) else {
            throw ImportError.wireGuard("Interface: PrivateKey must be a valid 32-byte WireGuard key.", subject: "interface.privatekey")
        }
        guard !peers.isEmpty else {
            throw ImportError.wireGuard("The configuration must contain at least one Peer section.", subject: "peer")
        }
        let address = interface["address"]
        let mtu = interface["mtu"]
        if let mtu, (Int(mtu).map { !(576...65535).contains($0) } ?? true) {
            throw ImportError.wireGuard("Interface: MTU must be between 576 and 65535.", subject: "interface.mtu")
        }
        let reserved = interface["reserved"]
        if let reserved, !validReserved(reserved) {
            throw ImportError.wireGuard("Interface: Reserved must contain exactly three bytes from 0 to 255.", subject: "interface.reserved")
        }
        var result: [Candidate] = []
        for (index, peer) in peers.enumerated() {
            guard let publicKey = peer["publickey"], validWireGuardKey(publicKey) else {
                throw ImportError.wireGuard("Peer \(index + 1): PublicKey must be a valid 32-byte WireGuard key.", subject: "peer-\(index + 1).publickey")
            }
            guard let endpoint = peer["endpoint"], let parsedEndpoint = splitEndpoint(endpoint) else {
                throw ImportError.wireGuard("Peer \(index + 1): Endpoint must include a host and port.", subject: "peer-\(index + 1).endpoint")
            }
            if let psk = peer["presharedkey"], !validWireGuardKey(psk) {
                throw ImportError.wireGuard("Peer \(index + 1): PresharedKey must be a valid 32-byte key.", subject: "peer-\(index + 1).presharedkey")
            }
            if let keepAlive = peer["persistentkeepalive"], (Int(keepAlive).map { !(0...65535).contains($0) } ?? true) {
                throw ImportError.wireGuard("Peer \(index + 1): PersistentKeepalive is invalid.", subject: "peer-\(index + 1).persistentkeepalive")
            }
            var parameters = ["secret-key": secretKey, "public-key": publicKey, "no-kernel-tun": "true"]
            if let address { parameters["address"] = address }
            if let mtu { parameters["mtu"] = mtu }
            if let reserved { parameters["reserved"] = reserved }
            if let dns = interface["dns"] { parameters["remote-dns"] = dns }
            if let allowed = peer["allowedips"] { parameters["allowed-ips"] = allowed }
            if let psk = peer["presharedkey"] { parameters["pre-shared-key"] = psk }
            if let keepAlive = peer["persistentkeepalive"] { parameters["keep-alive"] = keepAlive }
            result.append(Candidate(proto: .wireguard, host: parsedEndpoint.host, port: parsedEndpoint.port, name: parsedEndpoint.host, parameters: parameters))
        }
        return result
    }

    private func splitEndpoint(_ value: String) -> (host: String, port: Int)? {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("[") {
            guard let close = value.firstIndex(of: "]"), value[close...].hasPrefix("]:") else { return nil }
            let host = String(value[value.index(after: value.startIndex)..<close])
            guard let port = Int(value[value.index(close, offsetBy: 2)...]), (1...65535).contains(port) else { return nil }
            return (host, port)
        }
        guard let colon = value.lastIndex(of: ":"), value.firstIndex(of: ":") == colon else { return nil }
        let host = String(value[..<colon])
        guard !host.isEmpty, let port = Int(value[value.index(after: colon)...]), (1...65535).contains(port) else { return nil }
        return (host, port)
    }

    private func validWireGuardKey(_ value: String) -> Bool {
        if value.count == 64, value.allSatisfy({ $0.isHexDigit }) { return true }
        var encoded = value
        encoded += String(repeating: "=", count: (4 - encoded.count % 4) % 4)
        let data = Data(base64Encoded: encoded.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/"))
        return data?.count == 32
    }

    private func validReserved(_ value: String) -> Bool {
        let parts = value.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        return parts.count == 3 && parts.allSatisfy { (0...255).contains($0) }
    }

    private static func detectedFormat(for scheme: String) -> String {
        switch scheme {
        case "hy2": return "hysteria2"
        case "socks": return "socks5"
        default: return scheme
        }
    }

    private func parseVmess(_ value: String) throws -> Candidate {
        guard let data = decodeBase64(String(value.dropFirst("vmess://".count))),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let host = object["add"] as? String,
              let port = Int(String(describing: object["port"] ?? "")), (1...65_535).contains(port),
              let uuid = object["id"] as? String, UUID(uuidString: uuid) != nil else { throw ImportError.invalid }
        var parameters: [String: String] = ["uuid": uuid]
        if let network = stringValue(object["net"] ?? object["type"]) { parameters["network"] = network }
        if let tls = stringValue(object["tls"]), !tls.isEmpty { parameters["tls"] = tls == "tls" || tls == "true" ? "true" : "false" }
        if let sni = stringValue(object["sni"]), !sni.isEmpty { parameters["servername"] = sni }
        if let hostHeader = stringValue(object["host"]), !hostHeader.isEmpty { parameters["host"] = hostHeader }
        if let path = stringValue(object["path"]), !path.isEmpty { parameters["ws-opts.path"] = path }
        if let cipher = stringValue(object["scy"]), !cipher.isEmpty { parameters["cipher"] = cipher }
        if let aid = stringValue(object["aid"]), !aid.isEmpty { parameters["alterid"] = aid }
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
        if let url = URL(string: "ss://" + withoutName), let host = url.host, let port = url.port,
           let rawUser = decoded(url.user), rawUser.contains(":") {
            return try shadowsocksCandidate(methodPassword: rawUser, host: host, port: port, name: name ?? host)
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

    private func firstQueryValue(_ values: [String: String], keys: [String]) -> String? {
        keys.compactMap { values[$0] }.first
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
    private func diagnostic(_ code: String, _ message: String, subject: String) -> ConfigurationDiagnostic {
        .init(severity: .warning, code: code, subject: subject, message: message)
    }
    private enum ImportError: Error {
        case invalid
        case wireGuard(String, subject: String)

        var message: String {
            switch self {
            case .invalid: return "The proxy link is invalid."
            case let .wireGuard(message, _): return message
            }
        }

        var subject: String {
            switch self {
            case .invalid: return "link"
            case let .wireGuard(_, subject): return subject
            }
        }
    }
}
