import Foundation

/// Applies the supported scalar settings at the YAML document root while
/// leaving the immutable profile data and all unrelated sections untouched.
public struct RuntimeConfigurationComposer: Sendable {
    private let validator: RuntimeOverrideValidator

    public init(validator: RuntimeOverrideValidator = RuntimeOverrideValidator()) {
        self.validator = validator
    }

    public func applying(
        _ overrides: RuntimeOverrides,
        to profileData: Data,
        networkExtensionListener: NetworkExtensionMihomoListenerConfiguration? = nil
    ) throws -> Data {
        try validator.validate(overrides)
        guard !overrides.isEmpty || networkExtensionListener != nil else { return profileData }
        guard let yaml = String(data: profileData, encoding: .utf8) else {
            throw RuntimeConfigurationComposerError.profileIsNotUTF8
        }

        let newline = yaml.contains("\r\n") ? "\r\n" : "\n"
        var lines = YAMLLine.split(yaml)
        let prependRules = overrides.prependRules ?? []
        let appendRules = overrides.appendRules ?? []
        if !prependRules.isEmpty || !appendRules.isEmpty {
            lines = try applyingRuleOverrides(
                prepend: prependRules,
                append: appendRules,
                to: lines,
                newline: newline
            )
        }
        if let networkExtensionListener {
            lines = try applyingNetworkExtensionListener(
                networkExtensionListener,
                to: lines,
                newline: newline
            )
        }
        let entries = try encodedEntries(for: overrides)
        var overriddenKeys = Set(entries.map(\.key))
        if overrides.dns != nil {
            overriddenKeys.insert("dns")
        }

        var output: [YAMLLine] = []
        var index = 0
        var documentStartCount = 0
        while index < lines.count {
            let line = lines[index]
            if line.isRootDocumentStart {
                documentStartCount += 1
                if documentStartCount > 1 {
                    throw RuntimeConfigurationComposerError.multipleYAMLDocumentsUnsupported
                }
            }

            guard let key = line.rootMappingKey, overriddenKeys.contains(key) else {
                output.append(line)
                index += 1
                continue
            }

            // Remove the complete root value. Besides ordinary indented block
            // content, this deliberately consumes indentless sequences and
            // multi-line flow mappings. Root comments and blank lines are
            // retained because they are not part of the data node.
            index += 1
            while index < lines.count {
                let continuation = lines[index]
                if continuation.rootMappingKey != nil
                    || continuation.isRootDocumentStart
                    || continuation.isRootDocumentEnd
                    || continuation.isRootDirective {
                    break
                }
                if continuation.isRootTrivia {
                    output.append(continuation)
                }
                index += 1
            }
        }

        lines = output
        let insertionIndex = lines.lastIndex(where: \.isRootDocumentEnd) ?? lines.endIndex
        var rendered = lines.map(\.raw)
        var insertion = entries.map { YAMLLine(raw: "\($0.key): \($0.value)\(newline)") }.map(\.raw)
        if let dns = overrides.dns {
            insertion.append(contentsOf: try encodedDNSSection(dns, newline: newline))
        }

        if !insertion.isEmpty,
           insertionIndex > 0,
           !rendered[insertionIndex - 1].hasSuffix("\n"),
           !rendered[insertionIndex - 1].hasSuffix("\r") {
            insertion.insert(newline, at: 0)
        }
        if !insertion.isEmpty {
            rendered.insert(contentsOf: insertion, at: insertionIndex)
        }
        return Data(rendered.joined().utf8)
    }

    /// Reads the original profile's common listener declarations before any
    /// MClash override layer is applied. The port editor uses this baseline so
    /// "Use Profile" remains truthful while disconnected or while a custom
    /// override is active.
    public func listenerPorts(in profileData: Data) throws -> RuntimePortOverrides {
        guard let yaml = String(data: profileData, encoding: .utf8) else {
            throw RuntimeConfigurationComposerError.profileIsNotUTF8
        }

        var result = RuntimePortOverrides()
        for line in YAMLLine.split(yaml) {
            guard let key = line.rootMappingKey,
                  let value = line.rootIntegerValue else { continue }
            switch key {
            case "port": result.port = value
            case "socks-port": result.socksPort = value
            case "mixed-port": result.mixedPort = value
            default: continue
            }
        }
        return result
    }

    public func applying(
        _ overrides: RuntimeOverrides,
        toProfileAt url: URL,
        networkExtensionListener: NetworkExtensionMihomoListenerConfiguration? = nil
    ) throws -> Data {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        return try applying(
            overrides,
            to: data,
            networkExtensionListener: networkExtensionListener
        )
    }

    private func encodedEntries(for overrides: RuntimeOverrides) throws -> [(key: String, value: String)] {
        var entries: [(String, String)] = []
        append(overrides.ports.port, key: "port", to: &entries)
        append(overrides.ports.socksPort, key: "socks-port", to: &entries)
        append(overrides.ports.redirPort, key: "redir-port", to: &entries)
        append(overrides.ports.tproxyPort, key: "tproxy-port", to: &entries)
        append(overrides.ports.mixedPort, key: "mixed-port", to: &entries)
        append(overrides.allowLAN, key: "allow-lan", to: &entries)
        try append(overrides.bindAddress, key: "bind-address", to: &entries)
        append(overrides.ipv6, key: "ipv6", to: &entries)
        append(overrides.sniffing, key: "sniffing", to: &entries)
        append(overrides.tcpConcurrent, key: "tcp-concurrent", to: &entries)
        try append(overrides.findProcessMode, key: "find-process-mode", to: &entries)
        try append(overrides.interfaceName, key: "interface-name", to: &entries)
        try append(overrides.logLevel, key: "log-level", to: &entries)
        return entries
    }

    private func applyingRuleOverrides(
        prepend: [String],
        append: [String],
        to lines: [YAMLLine],
        newline: String
    ) throws -> [YAMLLine] {
        let rulesIndices = lines.indices.filter { lines[$0].rootMappingKey == "rules" }
        guard rulesIndices.count <= 1 else {
            throw RuntimeConfigurationComposerError.multipleRulesSectionsUnsupported
        }
        guard let rulesIndex = rulesIndices.first else {
            return try insertingNewRulesSection(
                prepend: prepend,
                append: append,
                into: lines,
                newline: newline
            )
        }

        var sectionEnd = rulesIndex + 1
        while sectionEnd < lines.count {
            let line = lines[sectionEnd]
            if line.rootMappingKey != nil
                || line.isRootDocumentStart
                || line.isRootDocumentEnd
                || line.isRootDirective {
                break
            }
            sectionEnd += 1
        }

        switch lines[rulesIndex].rootValueStyle {
        case .block:
            return try applyingRulesToBlockSequence(
                prepend: prepend,
                append: append,
                rulesIndex: rulesIndex,
                sectionEnd: sectionEnd,
                lines: lines,
                newline: newline
            )
        case .flowSequence:
            return try applyingRulesToFlowSequence(
                prepend: prepend,
                append: append,
                rulesIndex: rulesIndex,
                sectionEnd: sectionEnd,
                lines: lines
            )
        case .other:
            throw RuntimeConfigurationComposerError.rulesSectionMustBeSequence
        }
    }

    private func applyingRulesToBlockSequence(
        prepend: [String],
        append: [String],
        rulesIndex: Int,
        sectionEnd: Int,
        lines: [YAMLLine],
        newline: String
    ) throws -> [YAMLLine] {
        let content = Array(lines[(rulesIndex + 1)..<sectionEnd])
        var sequencePrefix: String?
        for line in content where !line.isYAMLTrivia {
            guard let prefix = line.sequenceItemPrefix else {
                throw RuntimeConfigurationComposerError.rulesSectionMustBeSequence
            }
            sequencePrefix = sequencePrefix ?? prefix
        }
        let prefix = sequencePrefix ?? "  "

        var replacement = [lines[rulesIndex].raw]
        try appendRuleLines(prepend, prefix: prefix, newline: newline, to: &replacement)
        appendRawLines(content.map(\.raw), newline: newline, to: &replacement)
        try appendRuleLines(append, prefix: prefix, newline: newline, to: &replacement)

        var rendered = lines.map(\.raw)
        rendered.replaceSubrange(rulesIndex..<sectionEnd, with: replacement)
        return YAMLLine.split(rendered.joined())
    }

    private func applyingRulesToFlowSequence(
        prepend: [String],
        append: [String],
        rulesIndex: Int,
        sectionEnd: Int,
        lines: [YAMLLine]
    ) throws -> [YAMLLine] {
        let section = lines[rulesIndex..<sectionEnd].map(\.raw).joined()
        guard let colon = section.firstIndex(of: ":"),
              let opening = section[section.index(after: colon)...].firstIndex(where: { !$0.isWhitespace }),
              section[opening] == "[",
              let closing = flowSequenceClosingBracket(in: section, openingAt: opening) else {
            throw RuntimeConfigurationComposerError.rulesSectionMustBeSequence
        }

        let bodyStart = section.index(after: opening)
        var body = String(section[bodyStart..<closing])
        let encodedPrepend = try prepend.map(yamlQuoted).joined(separator: ", ")
        let encodedAppend = try append.map(yamlQuoted).joined(separator: ", ")
        let hasExistingRules = !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        if !hasExistingRules {
            body = ([encodedPrepend, encodedAppend].filter { !$0.isEmpty }).joined(separator: ", ")
        } else {
            if !encodedPrepend.isEmpty {
                body = encodedPrepend + ", " + body
            }
            if !encodedAppend.isEmpty {
                let trailingWhitespace = body.reversed().prefix(while: \.isWhitespace).count
                let insertion = body.index(body.endIndex, offsetBy: -trailingWhitespace)
                body.insert(contentsOf: ", " + encodedAppend, at: insertion)
            }
        }

        let replacement = String(section[...opening]) + body + String(section[closing...])
        var rendered = lines.map(\.raw)
        rendered.replaceSubrange(rulesIndex..<sectionEnd, with: [replacement])
        return YAMLLine.split(rendered.joined())
    }

    private func insertingNewRulesSection(
        prepend: [String],
        append: [String],
        into lines: [YAMLLine],
        newline: String
    ) throws -> [YAMLLine] {
        let insertionIndex = lines.lastIndex(where: \.isRootDocumentEnd) ?? lines.endIndex
        var insertion = ["rules:\(newline)"]
        try appendRuleLines(prepend + append, prefix: "  ", newline: newline, to: &insertion)

        var rendered = lines.map(\.raw)
        if insertionIndex > 0,
           !rendered[insertionIndex - 1].hasSuffix("\n"),
           !rendered[insertionIndex - 1].hasSuffix("\r") {
            insertion.insert(newline, at: 0)
        }
        rendered.insert(contentsOf: insertion, at: insertionIndex)
        return YAMLLine.split(rendered.joined())
    }

    private func appendRuleLines(
        _ rules: [String],
        prefix: String,
        newline: String,
        to output: inout [String]
    ) throws {
        guard !rules.isEmpty else { return }
        appendRawLines(
            try rules.map { "\(prefix)- \(try yamlQuoted($0))\(newline)" },
            newline: newline,
            to: &output
        )
    }

    private func appendRawLines(
        _ lines: [String],
        newline: String,
        to output: inout [String]
    ) {
        guard !lines.isEmpty else { return }
        if !output.isEmpty,
           !output[output.count - 1].hasSuffix("\n"),
           !output[output.count - 1].hasSuffix("\r") {
            output[output.count - 1] += newline
        }
        output.append(contentsOf: lines)
    }

    private func flowSequenceClosingBracket(
        in value: String,
        openingAt opening: String.Index
    ) -> String.Index? {
        var index = opening
        var depth = 0
        var quote: Character?
        var escaped = false
        var comment = false

        while index < value.endIndex {
            let character = value[index]
            let next = value.index(after: index)
            if comment {
                if character == "\n" || character == "\r" { comment = false }
            } else if escaped {
                escaped = false
            } else if quote == "\"", character == "\\" {
                escaped = true
            } else if let activeQuote = quote {
                if character == activeQuote {
                    if activeQuote == "'", next < value.endIndex, value[next] == "'" {
                        index = value.index(after: next)
                        continue
                    }
                    quote = nil
                }
            } else if character == "\"" || character == "'" {
                quote = character
            } else if character == "#" {
                comment = true
            } else if character == "[" {
                depth += 1
            } else if character == "]" {
                depth -= 1
                if depth == 0 { return index }
            }
            index = next
        }
        return nil
    }

    private func applyingNetworkExtensionListener(
        _ configuration: NetworkExtensionMihomoListenerConfiguration,
        to lines: [YAMLLine],
        newline: String
    ) throws -> [YAMLLine] {
        let listenerIndices = lines.indices.filter { lines[$0].rootMappingKey == "listeners" }
        guard listenerIndices.count <= 1 else {
            throw RuntimeConfigurationComposerError.multipleListenersSectionsUnsupported
        }
        guard let listenersIndex = listenerIndices.first else {
            return try insertingNetworkExtensionListeners(
                configuration,
                into: lines,
                newline: newline
            )
        }

        var sectionEnd = listenersIndex + 1
        while sectionEnd < lines.count {
            let line = lines[sectionEnd]
            if line.rootMappingKey != nil
                || line.isRootDocumentStart
                || line.isRootDocumentEnd
                || line.isRootDirective {
                break
            }
            sectionEnd += 1
        }

        let section = lines[listenersIndex ..< sectionEnd].map(\.raw).joined()
        try rejectReservedListenerNameConflicts(in: section)

        switch lines[listenersIndex].rootValueStyle {
        case .block:
            return try appendingNetworkExtensionListenersToBlockSequence(
                configuration,
                listenersIndex: listenersIndex,
                sectionEnd: sectionEnd,
                lines: lines,
                newline: newline
            )
        case .flowSequence:
            return try appendingNetworkExtensionListenersToFlowSequence(
                configuration,
                listenersIndex: listenersIndex,
                sectionEnd: sectionEnd,
                lines: lines
            )
        case .other:
            throw RuntimeConfigurationComposerError.listenersSectionMustBeSequence
        }
    }

    private func insertingNetworkExtensionListeners(
        _ configuration: NetworkExtensionMihomoListenerConfiguration,
        into lines: [YAMLLine],
        newline: String
    ) throws -> [YAMLLine] {
        let insertionIndex = lines.lastIndex(where: \.isRootDocumentEnd) ?? lines.endIndex
        var insertion = ["listeners:\(newline)"]
        insertion.append(contentsOf: try encodedNetworkExtensionListenerBlocks(
            configuration,
            sequencePrefix: "  ",
            newline: newline
        ))

        var rendered = lines.map(\.raw)
        if insertionIndex > 0,
           !rendered[insertionIndex - 1].hasSuffix("\n"),
           !rendered[insertionIndex - 1].hasSuffix("\r") {
            insertion.insert(newline, at: 0)
        }
        rendered.insert(contentsOf: insertion, at: insertionIndex)
        return YAMLLine.split(rendered.joined())
    }

    private func appendingNetworkExtensionListenersToBlockSequence(
        _ configuration: NetworkExtensionMihomoListenerConfiguration,
        listenersIndex: Int,
        sectionEnd: Int,
        lines: [YAMLLine],
        newline: String
    ) throws -> [YAMLLine] {
        let content = Array(lines[(listenersIndex + 1) ..< sectionEnd])
        let firstDataLine = content.first(where: { !$0.isYAMLTrivia })
        let sequencePrefix: String
        if let firstDataLine {
            guard let prefix = firstDataLine.sequenceItemPrefix else {
                throw RuntimeConfigurationComposerError.listenersSectionMustBeSequence
            }
            sequencePrefix = prefix
        } else {
            sequencePrefix = "  "
        }

        var replacement = lines[listenersIndex ..< sectionEnd].map(\.raw)
        appendRawLines(
            try encodedNetworkExtensionListenerBlocks(
                configuration,
                sequencePrefix: sequencePrefix,
                newline: newline
            ),
            newline: newline,
            to: &replacement
        )

        var rendered = lines.map(\.raw)
        rendered.replaceSubrange(listenersIndex ..< sectionEnd, with: replacement)
        return YAMLLine.split(rendered.joined())
    }

    private func appendingNetworkExtensionListenersToFlowSequence(
        _ configuration: NetworkExtensionMihomoListenerConfiguration,
        listenersIndex: Int,
        sectionEnd: Int,
        lines: [YAMLLine]
    ) throws -> [YAMLLine] {
        let section = lines[listenersIndex ..< sectionEnd].map(\.raw).joined()
        guard let colon = section.firstIndex(of: ":"),
              let opening = section[section.index(after: colon)...].firstIndex(where: { !$0.isWhitespace }),
              section[opening] == "[",
              let closing = flowSequenceClosingBracket(in: section, openingAt: opening) else {
            throw RuntimeConfigurationComposerError.listenersSectionMustBeSequence
        }

        let bodyStart = section.index(after: opening)
        var body = String(section[bodyStart ..< closing])
        let generated = try encodedNetworkExtensionListenerFlowMappings(configuration)
            .joined(separator: ", ")
        if body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            body = generated
        } else {
            let trailingWhitespace = body.reversed().prefix(while: \.isWhitespace).count
            let insertion = body.index(body.endIndex, offsetBy: -trailingWhitespace)
            body.insert(contentsOf: ", " + generated, at: insertion)
        }

        let replacement = String(section[...opening]) + body + String(section[closing...])
        var rendered = lines.map(\.raw)
        rendered.replaceSubrange(listenersIndex ..< sectionEnd, with: [replacement])
        return YAMLLine.split(rendered.joined())
    }

    private func encodedNetworkExtensionListenerBlocks(
        _ configuration: NetworkExtensionMihomoListenerConfiguration,
        sequencePrefix: String,
        newline: String
    ) throws -> [String] {
        try [
            (NetworkExtensionMihomoListenerConfiguration.ipv4ListenerName,
             NetworkExtensionMihomoListenerConfiguration.ipv4Host),
            (NetworkExtensionMihomoListenerConfiguration.ipv6ListenerName,
             NetworkExtensionMihomoListenerConfiguration.ipv6Host),
        ].flatMap { name, host in
            let fieldPrefix = sequencePrefix + "  "
            var output = [
                "\(sequencePrefix)- name: \(try yamlQuoted(name))\(newline)",
                "\(fieldPrefix)type: socks\(newline)",
                "\(fieldPrefix)port: \(configuration.port)\(newline)",
                "\(fieldPrefix)listen: \(try yamlQuoted(host))\(newline)",
                "\(fieldPrefix)udp: true\(newline)",
            ]
            if let authentication = configuration.authentication {
                output.append("\(fieldPrefix)users:\(newline)")
                output.append(
                    "\(fieldPrefix)  - username: \(try yamlQuoted(authentication.username))\(newline)"
                )
                output.append(
                    "\(fieldPrefix)    password: \(try yamlQuoted(authentication.password))\(newline)"
                )
            } else {
                // Explicitly bypass the profile's global authentication. The
                // listener is private because its bind address is loopback.
                output.append("\(fieldPrefix)users: []\(newline)")
            }
            return output
        }
    }

    private func encodedNetworkExtensionListenerFlowMappings(
        _ configuration: NetworkExtensionMihomoListenerConfiguration
    ) throws -> [String] {
        try [
            (NetworkExtensionMihomoListenerConfiguration.ipv4ListenerName,
             NetworkExtensionMihomoListenerConfiguration.ipv4Host),
            (NetworkExtensionMihomoListenerConfiguration.ipv6ListenerName,
             NetworkExtensionMihomoListenerConfiguration.ipv6Host),
        ].map { name, host in
            let users: String
            if let authentication = configuration.authentication {
                users = "[{\"username\": \(try yamlQuoted(authentication.username)), "
                    + "\"password\": \(try yamlQuoted(authentication.password))}]"
            } else {
                users = "[]"
            }
            return "{\"name\": \(try yamlQuoted(name)), \"type\": \"socks\", "
                + "\"port\": \(configuration.port), \"listen\": \(try yamlQuoted(host)), "
                + "\"udp\": true, \"users\": \(users)}"
        }
    }

    private func rejectReservedListenerNameConflicts(in section: String) throws {
        for name in [
            NetworkExtensionMihomoListenerConfiguration.ipv4ListenerName,
            NetworkExtensionMihomoListenerConfiguration.ipv6ListenerName,
        ] where section.contains(name) {
            throw RuntimeConfigurationComposerError.reservedListenerNameConflict(name)
        }
    }

    private func encodedDNSSection(
        _ dns: RuntimeDNSOverrides,
        newline: String
    ) throws -> [String] {
        var fields: [String] = []
        appendDNS(dns.enable, key: "enable", newline: newline, to: &fields)
        try appendDNS(dns.listen, key: "listen", newline: newline, to: &fields)
        appendDNS(dns.ipv6, key: "ipv6", newline: newline, to: &fields)
        if let mode = dns.enhancedMode {
            try appendDNS(mode.rawValue, key: "enhanced-mode", newline: newline, to: &fields)
        }
        try appendDNS(dns.fakeIPRange, key: "fake-ip-range", newline: newline, to: &fields)
        try appendDNS(dns.fakeIPFilter, key: "fake-ip-filter", newline: newline, to: &fields)
        try appendDNS(dns.defaultNameserver, key: "default-nameserver", newline: newline, to: &fields)
        try appendDNS(dns.nameserver, key: "nameserver", newline: newline, to: &fields)
        try appendDNS(dns.fallback, key: "fallback", newline: newline, to: &fields)
        try appendDNS(
            dns.proxyServerNameserver,
            key: "proxy-server-nameserver",
            newline: newline,
            to: &fields
        )
        try appendDNS(
            dns.directNameserver,
            key: "direct-nameserver",
            newline: newline,
            to: &fields
        )
        appendDNS(dns.respectRules, key: "respect-rules", newline: newline, to: &fields)
        appendDNS(dns.useHosts, key: "use-hosts", newline: newline, to: &fields)
        appendDNS(dns.useSystemHosts, key: "use-system-hosts", newline: newline, to: &fields)
        appendDNS(dns.preferH3, key: "prefer-h3", newline: newline, to: &fields)

        if fields.isEmpty {
            return ["dns: {}\(newline)"]
        }
        return ["dns:\(newline)"] + fields
    }

    private func appendDNS(
        _ value: Bool?,
        key: String,
        newline: String,
        to fields: inout [String]
    ) {
        if let value {
            fields.append("  \(key): \(value ? "true" : "false")\(newline)")
        }
    }

    private func appendDNS(
        _ value: String?,
        key: String,
        newline: String,
        to fields: inout [String]
    ) throws {
        if let value {
            fields.append("  \(key): \(try yamlQuoted(value))\(newline)")
        }
    }

    private func appendDNS(
        _ values: [String]?,
        key: String,
        newline: String,
        to fields: inout [String]
    ) throws {
        guard let values else { return }
        guard !values.isEmpty else {
            fields.append("  \(key): []\(newline)")
            return
        }
        fields.append("  \(key):\(newline)")
        for value in values {
            fields.append("    - \(try yamlQuoted(value))\(newline)")
        }
    }

    private func append<T: BinaryInteger>(
        _ value: T?,
        key: String,
        to entries: inout [(String, String)]
    ) {
        if let value { entries.append((key, String(value))) }
    }

    private func append(
        _ value: Bool?,
        key: String,
        to entries: inout [(String, String)]
    ) {
        if let value { entries.append((key, value ? "true" : "false")) }
    }

    private func append(
        _ value: String?,
        key: String,
        to entries: inout [(String, String)]
    ) throws {
        if let value { entries.append((key, try yamlQuoted(value))) }
    }

    private func yamlQuoted(_ value: String) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        let data = try encoder.encode(value)
        guard let encoded = String(data: data, encoding: .utf8) else {
            throw RuntimeConfigurationComposerError.scalarEncodingFailed
        }
        // JSON strings are a valid subset of YAML double-quoted scalars.
        return encoded
    }
}

public enum RuntimeConfigurationComposerError: Error, Equatable, Sendable {
    case profileIsNotUTF8
    case multipleYAMLDocumentsUnsupported
    case multipleRulesSectionsUnsupported
    case multipleListenersSectionsUnsupported
    case rulesSectionMustBeSequence
    case listenersSectionMustBeSequence
    case reservedListenerNameConflict(String)
    case scalarEncodingFailed
}

extension RuntimeConfigurationComposerError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .profileIsNotUTF8:
            "The profile is not valid UTF-8 YAML."
        case .multipleYAMLDocumentsUnsupported:
            "Runtime overrides do not support profiles containing multiple YAML documents."
        case .multipleRulesSectionsUnsupported:
            "Runtime rule overrides do not support profiles containing duplicate top-level rules sections."
        case .multipleListenersSectionsUnsupported:
            "The Network Extension listener layer does not support profiles containing duplicate top-level listeners sections."
        case .rulesSectionMustBeSequence:
            "The profile's top-level rules value must be a block or inline YAML sequence."
        case .listenersSectionMustBeSequence:
            "The profile's top-level listeners value must be a block or inline YAML sequence."
        case let .reservedListenerNameConflict(name):
            "The profile already uses the reserved Network Extension listener name \(name)."
        case .scalarEncodingFailed:
            "A runtime override could not be encoded as a YAML scalar."
        }
    }
}

private struct YAMLLine {
    let raw: String

    static func split(_ value: String) -> [YAMLLine] {
        guard !value.isEmpty else { return [] }
        var result: [YAMLLine] = []
        var start = value.startIndex
        while start < value.endIndex {
            guard let newline = value[start...].firstIndex(of: "\n") else {
                result.append(YAMLLine(raw: String(value[start...])))
                break
            }
            let end = value.index(after: newline)
            result.append(YAMLLine(raw: String(value[start..<end])))
            start = end
        }
        return result
    }

    var isIndentedContent: Bool {
        guard let first = raw.first else { return false }
        return first == " " || first == "\t"
    }

    var isRootDocumentStart: Bool {
        !isIndentedContent && markerContent == "---"
    }

    var isRootDocumentEnd: Bool {
        !isIndentedContent && markerContent == "..."
    }

    var isRootDirective: Bool {
        !isIndentedContent && markerContent.hasPrefix("%")
    }

    var isRootTrivia: Bool {
        guard !isIndentedContent else { return false }
        let content = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return content.isEmpty || content.hasPrefix("#")
    }

    var isYAMLTrivia: Bool {
        let content = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return content.isEmpty || content.hasPrefix("#")
    }

    var sequenceItemPrefix: String? {
        let content = raw.trimmingCharacters(in: .newlines)
        let prefix = content.prefix { $0 == " " || $0 == "\t" }
        let indicator = content.dropFirst(prefix.count)
        guard indicator.first == "-" else { return nil }
        let remainder = indicator.dropFirst()
        guard remainder.isEmpty || remainder.first?.isWhitespace == true else { return nil }
        return String(prefix)
    }

    var rootValueStyle: RootYAMLValueStyle {
        guard rootMappingKey != nil,
              let colon = raw.firstIndex(of: ":") else { return .other }
        let valueStart = raw.index(after: colon)
        let value = yamlContentBeforeComment(String(raw[valueStart...]))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty { return .block }
        if value.first == "[" { return .flowSequence }
        return .other
    }

    var rootIntegerValue: Int? {
        guard rootMappingKey != nil,
              let colon = raw.firstIndex(of: ":") else { return nil }
        let valueStart = raw.index(after: colon)
        var value = yamlContentBeforeComment(String(raw[valueStart...]))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if value.first == "\"", value.last == "\"", value.count >= 2,
           let decoded = try? JSONDecoder().decode(String.self, from: Data(value.utf8)) {
            value = decoded
        } else if value.first == "'", value.last == "'", value.count >= 2 {
            value = String(value.dropFirst().dropLast())
                .replacingOccurrences(of: "''", with: "'")
        }
        return Int(value.replacingOccurrences(of: "_", with: ""))
    }

    private var markerContent: String {
        let withoutEnding = raw.trimmingCharacters(in: .newlines)
        let withoutComment = withoutEnding.split(
            separator: "#",
            maxSplits: 1,
            omittingEmptySubsequences: false
        )[0]
        return String(withoutComment).trimmingCharacters(in: .whitespaces)
    }

    var rootMappingKey: String? {
        guard let first = raw.first, first != " ", first != "\t", first != "#", first != "%" else {
            return nil
        }
        let withoutEnding = raw.trimmingCharacters(in: .newlines)
        guard let colon = withoutEnding.firstIndex(of: ":") else { return nil }
        let rawCandidate = String(withoutEnding[..<colon])
        let candidate = rawCandidate.trimmingCharacters(in: .whitespaces)
        guard !candidate.isEmpty else { return nil }

        if candidate.first == "\"", candidate.last == "\"", candidate.count >= 2 {
            let data = Data(candidate.utf8)
            return try? JSONDecoder().decode(String.self, from: data)
        }
        if candidate.first == "'", candidate.last == "'", candidate.count >= 2 {
            let inner = candidate.dropFirst().dropLast()
            return inner.replacingOccurrences(of: "''", with: "'")
        }
        guard candidate.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }) else {
            return nil
        }
        return String(candidate)
    }
}

private enum RootYAMLValueStyle {
    case block
    case flowSequence
    case other
}

private func yamlContentBeforeComment(_ value: String) -> String {
    var quote: Character?
    var escaped = false
    var index = value.startIndex
    while index < value.endIndex {
        let character = value[index]
        let next = value.index(after: index)
        if escaped {
            escaped = false
        } else if quote == "\"", character == "\\" {
            escaped = true
        } else if let activeQuote = quote {
            if character == activeQuote {
                if activeQuote == "'", next < value.endIndex, value[next] == "'" {
                    index = value.index(after: next)
                    continue
                }
                quote = nil
            }
        } else if character == "\"" || character == "'" {
            quote = character
        } else if character == "#" {
            return String(value[..<index])
        }
        index = next
    }
    return value
}
