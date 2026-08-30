import CryptoKit
import Foundation

public struct NodeImportReport: Codable, Equatable, Sendable {
    public let sourceID: SourceID
    public let nodes: [Node]
    public let ignoredSections: [String]
    public let diagnostics: [ConfigurationDiagnostic]
    public let importedAt: Date

    public var hasErrors: Bool {
        diagnostics.contains { $0.severity == .error }
    }

    public init(
        sourceID: SourceID,
        nodes: [Node],
        ignoredSections: [String],
        diagnostics: [ConfigurationDiagnostic],
        importedAt: Date = Date()
    ) {
        self.sourceID = sourceID
        self.nodes = nodes
        self.ignoredSections = ignoredSections
        self.diagnostics = diagnostics.sorted { $0.id < $1.id }
        self.importedAt = importedAt
    }
}

/// Extracts only the `proxies` sequence from common Mihomo YAML shapes. The
/// importer deliberately never interprets proxy-groups, rules, DNS, TUN or
/// other strategy sections as executable configuration.
public struct NodeOnlyImporter: Sendable {
    public init() {}

    public func importNodes(
        sourceID: SourceID,
        yaml: Data,
        now: Date = Date()
    ) -> NodeImportReport {
        guard let text = String(data: yaml, encoding: .utf8), !text.isEmpty else {
            return NodeImportReport(
                sourceID: sourceID,
                nodes: [],
                ignoredSections: [],
                diagnostics: [ConfigurationDiagnostic(
                    severity: .error,
                    code: "invalid_encoding",
                    subject: "source",
                    message: "The configuration is not valid UTF-8 YAML."
                )],
                importedAt: now
            )
        }

        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let rootKeys = Set(lines.compactMap { rootKey(in: stripComment($0)) })
        let ignoredNames = [
            "proxy-groups", "rules", "rule-providers", "proxy-providers", "dns", "tun", "listeners",
            "tunnels", "external-controller", "external-controller-tls", "profile",
        ]
        let ignored = ignoredNames.filter { rootKeys.contains($0) }
        let entries = proxyEntries(in: lines)
        var diagnostics: [ConfigurationDiagnostic] = []
        var nodes: [Node] = []
        var fingerprints = Set<String>()
        var connectionFingerprints: [String: String] = [:]

        for (index, fields) in entries.enumerated() {
            let subject = fields["name"] ?? "proxy-\(index + 1)"
            guard let host = fields["server"], !host.isEmpty,
                  let port = Int(fields["port"] ?? "") else {
                diagnostics.append(ConfigurationDiagnostic(
                    severity: .warning,
                    code: "node_missing_endpoint",
                    subject: subject,
                    message: "Skipped a proxy without a valid server and port."
                ))
                continue
            }

            let proto = NodeProtocol(rawValue: (fields["type"] ?? "unknown").lowercased()) ?? .unknown
            guard proto != .unknown else {
                diagnostics.append(ConfigurationDiagnostic(
                    severity: .warning,
                    code: "node_unsupported_protocol",
                    subject: subject,
                    message: "Skipped a proxy with an unsupported protocol type."
                ))
                continue
            }
            let parameters = fields.filter { key, _ in
                !["name", "type", "server", "port"].contains(key)
            }
            let fingerprint = Node.makeFingerprint(
                protocol: proto,
                host: host,
                port: port,
                parameters: parameters
            )
            guard fingerprints.insert(fingerprint).inserted else {
                let connectionFingerprint = Node.makeConnectionFingerprint(protocol: proto, host: host, port: port, parameters: parameters)
                let code = connectionFingerprints[fingerprint] == connectionFingerprint ? "duplicate_node" : "node_identity_conflict"
                diagnostics.append(ConfigurationDiagnostic(
                    severity: .warning,
                    code: code,
                    subject: subject,
                    message: code == "duplicate_node"
                        ? "Skipped a duplicate node with the same stable and connection identity."
                        : "Skipped a node whose endpoint identity matches another node but whose credentials or connection parameters differ."
                ))
                continue
            }
            connectionFingerprints[fingerprint] = Node.makeConnectionFingerprint(protocol: proto, host: host, port: port, parameters: parameters)

            do {
                let node = try Node(
                    id: NodeID.stable(for: fingerprint),
                    displayName: subject,
                    protocol: proto,
                    host: host,
                    port: port,
                    parameters: parameters,
                    sourceLinks: [sourceID],
                    lastSeenAt: now
                )
                nodes.append(node)
            } catch {
                diagnostics.append(ConfigurationDiagnostic(
                    severity: .warning,
                    code: "node_invalid_endpoint",
                    subject: subject,
                    message: error.localizedDescription
                ))
            }
        }

        if entries.isEmpty {
            diagnostics.append(ConfigurationDiagnostic(
                severity: .error,
                code: "missing_proxies",
                subject: "proxies",
                message: "The source did not contain a supported proxies sequence."
            ))
        }

        if !ignored.isEmpty {
            diagnostics.append(ConfigurationDiagnostic(
                severity: .warning,
                code: "strategy_sections_ignored",
                subject: "source",
                message: "MClash ignored source strategy sections: \(ignored.joined(separator: ", "))."
            ))
        }

        return NodeImportReport(
            sourceID: sourceID,
            nodes: nodes.sorted { $0.id.rawValue.uuidString < $1.id.rawValue.uuidString },
            ignoredSections: ignored,
            diagnostics: diagnostics,
            importedAt: now
        )
    }

    private func proxyEntries(in lines: [String]) -> [[String: String]] {
        guard let section = lines.firstIndex(where: {
            stripComment($0).trimmingCharacters(in: .whitespacesAndNewlines) == "proxies:"
        }) else { return [] }

        let sectionIndent = indentation(lines[section])
        var entries: [[String: String]] = []
        var current: [String: String] = [:]
        var currentIndent: Int?

        func flush() {
            if !current.isEmpty { entries.append(current) }
            current = [:]
        }

        for raw in lines.dropFirst(section + 1) {
            let line = stripComment(raw)
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let indent = indentation(line)
            if indent <= sectionIndent { break }

            if trimmed.hasPrefix("- {") || trimmed.hasPrefix("-{ ") || trimmed.hasPrefix("-{") {
                flush()
                let body = trimmed.dropFirst().trimmingCharacters(in: .whitespaces)
                current = parseInlineMap(String(body))
                flush()
                continue
            }

            if trimmed == "-" || trimmed.hasPrefix("- ") {
                if trimmed == "-" || topLevelColon(in: String(trimmed.dropFirst())) != nil {
                    flush()
                    currentIndent = indent
                    let body = trimmed.dropFirst().trimmingCharacters(in: .whitespaces)
                    if let colon = topLevelColon(in: body) {
                        let key = String(body[..<colon]).trimmingCharacters(in: .whitespaces)
                        let value = String(body[body.index(after: colon)...])
                        current[key] = scalar(value)
                    }
                    continue
                }
            }

            guard currentIndent != nil, indent > (currentIndent ?? sectionIndent),
                  let colon = topLevelColon(in: trimmed) else { continue }
            let key = String(trimmed[..<colon]).trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { continue }
            current[key] = scalar(String(trimmed[trimmed.index(after: colon)...]))
        }
        flush()
        return entries
    }

    private func rootKey(in line: String) -> String? {
        let value = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !value.hasPrefix("-"), let colon = topLevelColon(in: value) else {
            return nil
        }
        return String(value[..<colon]).trimmingCharacters(in: .whitespaces)
    }

    private func parseInlineMap(_ raw: String) -> [String: String] {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("{") { value.removeFirst() }
        if value.hasSuffix("}") { value.removeLast() }
        return splitTopLevel(value, separator: ",").reduce(into: [:]) { result, field in
            guard let colon = topLevelColon(in: field) else { return }
            let key = scalar(String(field[..<colon])).trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { return }
            result[key] = scalar(String(field[field.index(after: colon)...]))
        }
    }

    private func scalar(_ raw: String) -> String {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.count >= 2 else { return value }
        if value.first == "\"", value.last == "\"",
           let data = value.data(using: .utf8),
           let decoded = try? JSONDecoder().decode(String.self, from: data) {
            return decoded
        }
        if value.first == "'", value.last == "'" {
            return String(value.dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'")
        }
        return value
    }

    private func splitTopLevel(_ value: String, separator: Character) -> [String] {
        var result: [String] = []
        var start = value.startIndex
        var quote: Character?
        var depth = 0
        for index in value.indices {
            let character = value[index]
            if character == "'" || character == "\"" {
                quote = quote == character ? nil : (quote == nil ? character : quote)
            } else if quote == nil, character == "[" || character == "{" { depth += 1 }
            else if quote == nil, character == "]" || character == "}" { depth = max(0, depth - 1) }
            else if quote == nil, character == separator, depth == 0 {
                result.append(String(value[start..<index]))
                start = value.index(after: index)
            }
        }
        result.append(String(value[start...]))
        return result
    }

    private func topLevelColon(in value: String) -> String.Index? {
        var quote: Character?
        var depth = 0
        for index in value.indices {
            let character = value[index]
            if character == "'" || character == "\"" {
                quote = quote == character ? nil : (quote == nil ? character : quote)
            } else if quote == nil, character == "[" || character == "{" { depth += 1 }
            else if quote == nil, character == "]" || character == "}" { depth = max(0, depth - 1) }
            else if quote == nil, character == ":", depth == 0 { return index }
        }
        return nil
    }

    private func indentation(_ value: String) -> Int {
        value.prefix { $0 == " " || $0 == "\t" }.reduce(into: 0) { $0 += $1 == "\t" ? 2 : 1 }
    }

    private func stripComment(_ value: String) -> String {
        var quote: Character?
        var escaped = false
        for index in value.indices {
            let character = value[index]
            if escaped { escaped = false }
            else if character == "\\", quote == "\"" { escaped = true }
            else if character == "'" || character == "\"" { quote = quote == character ? nil : (quote == nil ? character : quote) }
            else if character == "#", quote == nil { return String(value[..<index]) }
        }
        return value
    }
}

public extension NodeID {
    /// Stable UUID derived from a SHA-256 fingerprint without retaining any
    /// provider-controlled display name.
    static func stable(for fingerprint: String) -> Self {
        let digest = SHA256Compat.digest(Data(fingerprint.utf8))
        let bytes = Array(digest.prefix(16))
        let uuid = UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
        ))
        return Self(rawValue: uuid)
    }
}

private enum SHA256Compat {
    static func digest(_ data: Data) -> [UInt8] {
        Array(SHA256.hash(data: data))
    }
}
