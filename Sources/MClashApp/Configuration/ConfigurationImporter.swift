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
                    message: AppLocalization.string("The configuration is not valid UTF-8 YAML.")
                )],
                importedAt: now
            )
        }

        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let rootKeys = Set(lines.compactMap { rootKey(in: $0) })
        let ignoredNames = [
            "proxy-groups", "rules", "rule-providers", "proxy-providers", "dns", "tun", "listeners",
            "tunnels", "external-controller", "external-controller-tls", "profile",
        ]
        let ignored = ignoredNames.filter { rootKeys.contains($0) }
        let entries = proxyEntries(in: lines)
        var diagnostics: [ConfigurationDiagnostic] = []
        var nodes: [Node] = []
        var connectionFingerprints = Set<String>()
        var candidates: [(subject: String, proto: NodeProtocol, host: String, port: Int, parameters: [String: String], tags: Set<String>, region: String?, fingerprint: String, connectionFingerprint: String)] = []

        for (index, fields) in entries.enumerated() {
            let subject = fields["name"] ?? "proxy-\(index + 1)"
            guard let host = fields["server"], !host.isEmpty,
                  let port = Int(fields["port"] ?? "") else {
                diagnostics.append(ConfigurationDiagnostic(
                    severity: .warning,
                    code: "node_missing_endpoint",
                    subject: subject,
                    message: AppLocalization.string("Skipped a proxy without a valid server and port.")
                ))
                continue
            }

            let rawProtocol = (fields["type"] ?? "unknown").lowercased()
            let proto = rawProtocol == "ss"
                ? NodeProtocol.shadowsocks
                : NodeProtocol(rawValue: rawProtocol) ?? .unknown
            guard proto != .unknown else {
                diagnostics.append(ConfigurationDiagnostic(
                    severity: .warning,
                    code: "node_unsupported_protocol",
                    subject: subject,
                    message: AppLocalization.string("Skipped a proxy with an unsupported protocol type.")
                ))
                continue
            }
            let parameters = fields.filter { key, _ in
                let normalizedKey = NodeIdentity.normalizeParameterKey(key)
                return !["name", "type", "server", "port"].contains(normalizedKey)
                    && !NodeIdentity.isPresentationParameter(normalizedKey)
            }
            let importedTags = metadataTags(in: fields, keys: ["tags", "tag"])
            let tags: Set<String>
            if configurationAutomationTagsAreValid(importedTags) {
                tags = importedTags
            } else {
                tags = []
                diagnostics.append(ConfigurationDiagnostic(
                    severity: .warning,
                    code: "node_tags_ignored",
                    subject: subject,
                    message: AppLocalization.string(
                        "Configuration exceeds a supported resource limit."
                    )
                ))
            }
            let region = metadataValue(in: fields, keys: ["region", "country"])
            let fingerprint = Node.makeFingerprint(
                protocol: proto,
                host: host,
                port: port,
                parameters: parameters
            )
            let connectionFingerprint = Node.makeConnectionFingerprint(protocol: proto, host: host, port: port, parameters: parameters)
            guard connectionFingerprints.insert(connectionFingerprint).inserted else {
                diagnostics.append(ConfigurationDiagnostic(
                    severity: .warning,
                    code: "duplicate_node",
                    subject: subject,
                    message: AppLocalization.string("Skipped a duplicate node with the same stable and connection identity.")
                ))
                continue
            }
            candidates.append((subject, proto, host, port, parameters, tags, region, fingerprint, connectionFingerprint))
        }

        // Assign collision identities after the complete source has been
        // parsed. For one endpoint, IDs are derived from the endpoint alone;
        // when multiple credentials share it, every ID includes the full
        // connection fingerprint. Sorting/grouping this way makes identities
        // independent of provider entry order, so refreshing a subscription
        // cannot swap which account owns a pinned ID.
        let candidatesByFingerprint = Dictionary(grouping: candidates, by: { $0.fingerprint })
        for candidate in candidates {
            let siblings = candidatesByFingerprint[candidate.fingerprint] ?? []
            if siblings.count > 1 {
                diagnostics.append(ConfigurationDiagnostic(
                    severity: .warning,
                    code: "node_identity_conflict",
                    subject: candidate.subject,
                    message: AppLocalization.string("The source contains the same node endpoint with different credentials; both connection identities were retained for review.")
                ))
            }
            let identityMaterial = siblings.count > 1
                ? candidate.fingerprint + "|" + candidate.connectionFingerprint
                : candidate.fingerprint
            let stableID = NodeID.stable(for: identityMaterial)
            do {
                let node = try Node(
                    id: stableID,
                    displayName: candidate.subject,
                    protocol: candidate.proto,
                    host: candidate.host,
                    port: candidate.port,
                    parameters: candidate.parameters,
                    sourceLinks: [sourceID],
                    tags: candidate.tags,
                    region: candidate.region,
                    lastSeenAt: now
                )
                nodes.append(node)
            } catch {
                diagnostics.append(ConfigurationDiagnostic(
                    severity: .warning,
                    code: "node_invalid_endpoint",
                    subject: candidate.subject,
                    message: error.localizedDescription
                ))
            }
        }

        if entries.isEmpty {
            diagnostics.append(ConfigurationDiagnostic(
                severity: .error,
                code: "missing_proxies",
                subject: "proxies",
                message: AppLocalization.string("The source did not contain a supported proxies sequence.")
            ))
        }

        if !ignored.isEmpty {
            diagnostics.append(ConfigurationDiagnostic(
                severity: .warning,
                code: "strategy_sections_ignored",
                subject: "source",
                message: AppLocalization.format(
                    "MClash ignored source strategy sections: %@",
                    ignored.joined(separator: ", ")
                )
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
        // Only zero-indent mappings are document-level keys.  Looking at every
        // mapping line would mistake a node's nested parameter (for example a
        // transport field named `dns` or `tun`) for a strategy section.
        guard indentation(line) == 0 else { return nil }
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

    private func metadataValue(in fields: [String: String], keys: [String]) -> String? {
        for key in keys {
            if let value = fields.first(where: {
                NodeIdentity.normalizeParameterKey($0.key) == key
            })?.value {
                let normalized = scalar(value).trimmingCharacters(in: .whitespacesAndNewlines)
                if !normalized.isEmpty { return normalized }
            }
        }
        return nil
    }

    private func metadataTags(in fields: [String: String], keys: [String]) -> Set<String> {
        guard let raw = metadataValue(in: fields, keys: keys) else { return [] }
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.first == "[", value.last == "]" {
            value = String(value.dropFirst().dropLast())
        }
        return Set(value
            .split(whereSeparator: { $0 == "," || $0 == ";" || $0 == " " || $0 == "\t" || $0 == "\n" || $0 == "\r" })
            .map { scalar(String($0)).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty })
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
