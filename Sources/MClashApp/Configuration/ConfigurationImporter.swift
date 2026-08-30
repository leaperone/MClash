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
    private struct YAMLLine {
        var indent: Int
        let content: String
    }

    private indirect enum YAMLFragment {
        case scalar(String)
        case mapping([(String, YAMLFragment)])
        case sequence([YAMLFragment])
    }

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
        guard let section = lines.firstIndex(where: { rootKey(in: $0)?.lowercased() == "proxies" }) else {
            return []
        }

        let sectionLine = stripComment(lines[section])
        guard let sectionColon = topLevelColon(in: sectionLine) else { return [] }
        let inlineValue = String(sectionLine[sectionLine.index(after: sectionColon)...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !inlineValue.isEmpty {
            let withoutAnchor = inlineValue.replacingOccurrences(
                of: #"^&[^\s]+\s*"#,
                with: "",
                options: .regularExpression
            )
            if withoutAnchor.first == "[", withoutAnchor.last == "]" {
                return parseInlineSequence(withoutAnchor)
            }
            // A tagged/anchored block sequence may continue on following
            // lines. A non-empty scalar here is not a supported proxies
            // sequence and must not be mistaken for one.
            if !withoutAnchor.isEmpty,
               withoutAnchor != "~",
               withoutAnchor.lowercased() != "null" {
                return []
            }
        }

        let sectionIndent = indentation(lines[section])
        var entries: [[String: String]] = []
        var blockLines: [YAMLLine] = []
        var itemIndent: Int?

        func flush() {
            guard !blockLines.isEmpty else { return }
            var index = 0
            let fragment = parseYAMLBlock(
                blockLines,
                index: &index,
                indent: blockLines[0].indent
            )
            if case let .mapping(fields) = fragment {
                let entry = fields.reduce(into: [String: String]()) { result, field in
                    switch field.1 {
                    case let .scalar(value):
                        result[field.0] = value
                    case .mapping, .sequence:
                        result[field.0] = renderFlow(field.1)
                    }
                }
                if !entry.isEmpty { entries.append(entry) }
            }
            blockLines = []
        }

        for raw in lines.dropFirst(section + 1) {
            let line = stripComment(raw)
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let indent = indentation(line)
            // YAML permits an indentationless block sequence as the value of
            // a mapping key (`proxies:\n- name: ...`). Keep those root-level
            // sequence items attached to `proxies`; a subsequent root mapping
            // key still terminates the section as usual.
            if indent < sectionIndent || (indent == sectionIndent && !trimmed.hasPrefix("-")) {
                break
            }

            if trimmed.hasPrefix("- {") || trimmed.hasPrefix("-{ ") || trimmed.hasPrefix("-{") {
                flush()
                let body = trimmed.dropFirst().trimmingCharacters(in: .whitespaces)
                let entry = parseInlineMap(String(body))
                if !entry.isEmpty { entries.append(entry) }
                itemIndent = nil
                continue
            }

            if trimmed == "-" || trimmed.hasPrefix("- ") {
                if itemIndent == nil || indent <= (itemIndent ?? indent) {
                    flush()
                    itemIndent = indent
                    let body = trimmed.dropFirst().trimmingCharacters(in: .whitespaces)
                    if !body.isEmpty {
                        blockLines.append(YAMLLine(indent: indent + 2, content: body))
                    }
                    continue
                }
            }

            guard let itemIndent, indent > itemIndent else { continue }
            // The first mapping field after a sequence marker is initially
            // assigned the conventional +2 indentation. YAML also permits a
            // wider sibling indentation (for example four spaces after a
            // two-space list marker). Once the first real sibling is seen,
            // align that provisional field to the actual indentation. Do not
            // realign an empty-value field: its following line is a nested
            // value, not a sibling.
            if blockLines.count == 1,
               blockLines[0].indent == itemIndent + 2,
               let firstColon = topLevelColon(in: blockLines[0].content),
               !String(blockLines[0].content[blockLines[0].content.index(after: firstColon)...])
                    .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               indent > blockLines[0].indent {
                blockLines[0].indent = indent
            }
            blockLines.append(YAMLLine(indent: indent, content: trimmed))
        }
        flush()
        return entries
    }

    private func parseInlineSequence(_ raw: String) -> [[String: String]] {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.first == "[", value.last == "]" else { return [] }
        value.removeFirst()
        value.removeLast()
        return splitTopLevel(value, separator: ",").compactMap { element in
            let trimmed = element.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.first == "{", trimmed.last == "}" else { return nil }
            let fields = parseInlineMap(trimmed)
            return fields.isEmpty ? nil : fields
        }
    }

    private func parseYAMLBlock(
        _ lines: [YAMLLine],
        index: inout Int,
        indent: Int
    ) -> YAMLFragment {
        guard index < lines.count else { return .mapping([]) }
        if lines[index].content == "-" || lines[index].content.hasPrefix("- ") {
            return parseYAMLSequence(lines, index: &index, indent: indent)
        }
        return parseYAMLMapping(lines, index: &index, indent: indent)
    }

    private func parseYAMLMapping(
        _ lines: [YAMLLine],
        index: inout Int,
        indent: Int
    ) -> YAMLFragment {
        var fields: [(String, YAMLFragment)] = []
        while index < lines.count {
            let line = lines[index]
            guard line.indent == indent,
                  line.content != "-",
                  !line.content.hasPrefix("- "),
                  let colon = topLevelColon(in: line.content) else { break }
            let key = scalar(String(line.content[..<colon]))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let rawValue = String(line.content[line.content.index(after: colon)...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            index += 1
            let value: YAMLFragment
            if !rawValue.isEmpty {
                value = parseFlowFragment(rawValue) ?? .scalar(scalar(rawValue))
            } else if index < lines.count,
                      lines[index].indent > indent
                        || (lines[index].indent == indent
                            && (lines[index].content == "-"
                                || lines[index].content.hasPrefix("- "))) {
                value = parseYAMLBlock(lines, index: &index, indent: lines[index].indent)
            } else {
                value = .mapping([])
            }
            if !key.isEmpty { fields.append((key, value)) }
        }
        return .mapping(fields)
    }

    private func parseYAMLSequence(
        _ lines: [YAMLLine],
        index: inout Int,
        indent: Int
    ) -> YAMLFragment {
        var values: [YAMLFragment] = []
        while index < lines.count {
            let line = lines[index]
            guard line.indent == indent,
                  line.content == "-" || line.content.hasPrefix("- ") else { break }
            let body = line.content.dropFirst()
                .trimmingCharacters(in: .whitespacesAndNewlines)
            index += 1
            if body.isEmpty {
                if index < lines.count, lines[index].indent > indent {
                    values.append(parseYAMLBlock(lines, index: &index, indent: lines[index].indent))
                } else {
                    values.append(.scalar(""))
                }
            } else if topLevelColon(in: body) != nil {
                let provisionalIndent = indent + 2
                let bodyColon = topLevelColon(in: body)
                let bodyHasValue = bodyColon.map {
                    !String(body[body.index(after: $0)...])
                        .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                } ?? false
                let firstChildIndent = index < lines.count && lines[index].indent > indent
                    ? lines[index].indent
                    : provisionalIndent
                let itemIndent = bodyHasValue && firstChildIndent > provisionalIndent
                    ? firstChildIndent
                    : provisionalIndent
                var itemLines = [YAMLLine(indent: itemIndent, content: body)]
                let childStart = index
                while index < lines.count, lines[index].indent > indent {
                    itemLines.append(lines[index])
                    index += 1
                }
                var itemIndex = 0
                values.append(parseYAMLBlock(itemLines, index: &itemIndex, indent: itemIndent))
                if index == childStart { continue }
            } else {
                values.append(.scalar(scalar(body)))
            }
        }
        return .sequence(values)
    }

    private func renderFlow(_ fragment: YAMLFragment) -> String {
        switch fragment {
        case let .scalar(value):
            return flowScalar(value)
        case let .mapping(fields):
            guard !fields.isEmpty else { return "{}" }
            let orderedFields = fields.sorted { lhs, rhs in
                lhs.0 == rhs.0 ? renderFlow(lhs.1) < renderFlow(rhs.1) : lhs.0 < rhs.0
            }
            return "{ " + orderedFields.map { field in
                "\(flowScalar(field.0)): \(renderFlow(field.1))"
            }.joined(separator: ", ") + " }"
        case let .sequence(values):
            guard !values.isEmpty else { return "[]" }
            return "[" + values.map(renderFlow).joined(separator: ", ") + "]"
        }
    }

    private func parseFlowFragment(_ raw: String) -> YAMLFragment? {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = value.first, let last = value.last else { return nil }
        if first == "{" && last == "}" {
            value.removeFirst()
            value.removeLast()
            let components = splitTopLevel(value, separator: ",")
            var fields: [(String, YAMLFragment)] = []
            for field in components {
                let trimmed = field.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty { continue }
                guard let colon = topLevelColon(in: trimmed) else { return nil }
                let key = scalar(String(trimmed[..<colon])).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !key.isEmpty else { return nil }
                let rawValue = String(trimmed[trimmed.index(after: colon)...])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                fields.append((key, parseFlowFragment(rawValue) ?? .scalar(scalar(rawValue))))
            }
            return .mapping(fields)
        }
        if first == "[" && last == "]" {
            value.removeFirst()
            value.removeLast()
            let values = splitTopLevel(value, separator: ",")
                .map { parseFlowFragment($0) ?? .scalar(scalar($0)) }
            return .sequence(values.filter { fragment in
                if case let .scalar(value) = fragment {
                    return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                }
                return true
            })
        }
        return nil
    }

    private func flowScalar(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if ((trimmed.first == "{" && trimmed.last == "}")
            || (trimmed.first == "[" && trimmed.last == "]")),
           !trimmed.contains(where: { $0 == "\n" || $0 == "\r" }) {
            return trimmed
        }
        let lowercased = trimmed.lowercased()
        if ["true", "false", "null"].contains(lowercased) {
            return lowercased
        }
        if Double(trimmed) != nil { return trimmed }
        // JSON escaping is almost, but not quite, YAML escaping: JSON emits
        // a backslash before slashes, which YAML rejects as an unknown escape
        // inside a double-quoted flow scalar. Escape only characters YAML
        // double quotes actually reserve.
        let escaped = trimmed
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\u{0}", with: "")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\t", with: "\\t")
        return "\"\(escaped)\""
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
            let rawValue = String(field[field.index(after: colon)...])
            if let fragment = parseFlowFragment(rawValue) {
                result[key] = renderFlow(fragment)
            } else {
                result[key] = scalar(rawValue)
            }
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

public extension ConfigurationIdentifier {
    /// Stable UUID derived from a SHA-256 fingerprint without retaining any
    /// provider-controlled display name.
    static func stable(for fingerprint: String) -> Self {
        let digest = SHA256Compat.digest(Data(fingerprint.utf8))
        let bytes = Array(digest.prefix(16))
        let uuid = UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
        ))
        return Self(rawValue: uuid)!
    }
}

private enum SHA256Compat {
    static func digest(_ data: Data) -> [UInt8] {
        Array(SHA256.hash(data: data))
    }
}
