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

    /// Extracts every TCP/UDP listener port that the final primary mihomo
    /// configuration can bind. This is intentionally broader than the
    /// user-facing Mixed-port editor: Redirect, TProxy, DNS listen, custom
    /// listeners, and an existing external controller all share the same
    /// machine-wide port namespace with auxiliary profile sessions.
    public func boundListenerPorts(in configurationData: Data) throws -> Set<Int> {
        guard let yaml = String(data: configurationData, encoding: .utf8) else {
            throw RuntimeConfigurationComposerError.profileIsNotUTF8
        }
        let lines = YAMLLine.split(yaml)
        try Self.validateBoundListenerSyntax(in: yaml, lines: lines)
        var ports = Set<Int>()
        let rootIntegerKeys: Set<String> = [
            "port",
            "socks-port",
            "mixed-port",
            "redir-port",
            "tproxy-port",
        ]
        for line in lines {
            guard let key = line.rootMappingKey,
                  rootIntegerKeys.contains(key),
                  let port = line.rootIntegerValue,
                  (1...65_535).contains(port) else {
                continue
            }
            ports.insert(port)
        }

        for (index, line) in lines.enumerated() {
            guard let key = line.rootMappingKey,
                  ["dns", "listeners", "tuic-server", "tunnels"].contains(key) else {
                continue
            }
            var end = index + 1
            while end < lines.count {
                let candidate = lines[end]
                if candidate.rootMappingKey != nil
                    || candidate.isRootDocumentStart
                    || candidate.isRootDocumentEnd
                    || candidate.isRootDirective {
                    break
                }
                end += 1
            }
            let section = lines[index..<end].map(\.raw).joined()
            switch key {
            case "dns", "tuic-server":
                let pattern =
                    #"(?m)(?:^|[\{,])\s*["']?listen["']?\s*:\s*(?:!!str[ \t]+)?["']?(?:\[[^\]]+\]|[^\s,'"}]*):([0-9]{1,5})"#
                let endpointPorts = Self.capturedIntegerValues(
                    in: section,
                    pattern: pattern
                )
                guard endpointPorts.allSatisfy({ (0...65_535).contains($0) }) else {
                    throw RuntimeConfigurationComposerError
                        .unsupportedBoundListenerSyntax("\(key).listen")
                }
                ports.formUnion(endpointPorts.filter { $0 > 0 })
            case "listeners":
                let pattern =
                    #"(?m)(?:^|[\{,])\s*(?:-\s*)?["']?port["']?\s*:\s*(?:!!(?:int|str)[ \t]+)?["']?([0-9][0-9_,/ \t-]*)["']?[ \t]*(?=$|#|,|\}|\r?\n)"#
                ports.formUnion(
                    try Self.capturedPortSpecifications(
                        in: section,
                        pattern: pattern,
                        binding: "listeners.port"
                    )
                )
            case "tunnels":
                let addressPattern =
                    #"(?m)(?:^|[\{,])\s*(?:-\s*)?["']?address["']?\s*:\s*(?:!!str[ \t]+)?["']?(?:\[[^\]]+\]|[^\s,'"}]*):([0-9]{1,5})"#
                let compactPattern =
                    #"(?m)^\s*-\s*[^,\r\n]+,\s*(?:\[[^\]]+\]|[^,\s'"}]*):([0-9]{1,5})"#
                ports.formUnion(Self.capturedPorts(in: section, pattern: addressPattern))
                ports.formUnion(Self.capturedPorts(in: section, pattern: compactPattern))
            default:
                break
            }
        }

        for line in lines {
            guard let key = line.rootMappingKey,
                  let value = line.rootScalarValue else {
                continue
            }
            if key == "external-controller"
                || key == "external-controller-tls"
                || key == "ss-config"
                || key == "vmess-config" {
                if let port = Self.endpointPort(in: value) {
                    ports.insert(port)
                } else if key == "ss-config",
                          let port = Self.legacyShadowsocksPort(in: value) {
                    ports.insert(port)
                }
            }
        }
        return ports
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

    /// Removes profile-owned listener surfaces that cannot safely coexist in
    /// a multi-core process fleet. MClash adds back only its isolated Mixed
    /// and authenticated App Routing listeners after this pass.
    public func sanitizingForManagedSession(_ profileData: Data) throws -> Data {
        try sanitizing(
            profileData,
            removingRootKeys: [
                "listeners",
                "tun",
                "tunnels",
                "ss-config",
                "vmess-config",
                "tuic-server",
                "external-controller",
                "external-controller-tls",
                "external-controller-unix",
                "external-controller-pipe",
            ]
        )
    }

    /// Compatibility spelling for callers that explicitly describe an
    /// auxiliary session. Primary and auxiliary sessions intentionally share
    /// the same MClash-managed inbound surface.
    public func sanitizingForAuxiliarySession(_ profileData: Data) throws -> Data {
        try sanitizingForManagedSession(profileData)
    }

    private func sanitizing(
        _ profileData: Data,
        removingRootKeys removedKeys: Set<String>
    ) throws -> Data {
        guard let yaml = String(data: profileData, encoding: .utf8) else {
            throw RuntimeConfigurationComposerError.profileIsNotUTF8
        }
        var output: [YAMLLine] = []
        let lines = YAMLLine.split(yaml)
        try Self.validateRootMappingStructure(lines)
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
            guard let key = line.rootMappingKey,
                  removedKeys.contains(key) else {
                output.append(line)
                index += 1
                continue
            }
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
        return Data(output.map(\.raw).joined().utf8)
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

    private static func capturedPorts(
        in text: String,
        pattern: String
    ) -> Set<Int> {
        guard let expression = try? NSRegularExpression(pattern: pattern) else {
            return []
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return Set(expression.matches(in: text, range: range).compactMap { match in
            guard match.numberOfRanges > 1,
                  let portRange = Range(match.range(at: 1), in: text),
                  let port = Int(text[portRange]),
                  (1...65_535).contains(port) else {
                return nil
            }
            return port
        })
    }

    private static func capturedPortSpecifications(
        in text: String,
        pattern: String,
        binding: String
    ) throws -> Set<Int> {
        guard let expression = try? NSRegularExpression(pattern: pattern) else {
            return []
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        var ports = Set<Int>()
        for match in expression.matches(in: text, range: range) {
            guard match.numberOfRanges > 1,
                  let specificationRange = Range(match.range(at: 1), in: text) else {
                continue
            }
            var specification = String(text[specificationRange])
            specification = specification
                .replacingOccurrences(of: "_", with: "")
                .replacingOccurrences(of: "/", with: ",")
            let components = specification.split(
                separator: ",",
                omittingEmptySubsequences: false
            )
            guard !components.isEmpty else {
                throw RuntimeConfigurationComposerError
                    .unsupportedBoundListenerSyntax(binding)
            }
            for component in components {
                let trimmed = component.trimmingCharacters(in: .whitespaces)
                let bounds = trimmed.split(
                    separator: "-",
                    maxSplits: 1,
                    omittingEmptySubsequences: false
                ).map {
                    $0.trimmingCharacters(in: .whitespaces)
                }
                if bounds.count == 1,
                   let port = Int(bounds[0]),
                   (1...65_535).contains(port) {
                    ports.insert(port)
                } else if bounds.count == 2,
                          let lower = Int(bounds[0]),
                          let upper = Int(bounds[1]),
                          (1...65_535).contains(lower),
                          (1...65_535).contains(upper) {
                    ports.formUnion(min(lower, upper)...max(lower, upper))
                } else {
                    throw RuntimeConfigurationComposerError
                        .unsupportedBoundListenerSyntax(binding)
                }
            }
        }
        return ports
    }

    private static func capturedIntegerValues(
        in text: String,
        pattern: String
    ) -> [Int] {
        guard let expression = try? NSRegularExpression(pattern: pattern) else {
            return []
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return expression.matches(in: text, range: range).compactMap { match in
            guard match.numberOfRanges > 1,
                  let valueRange = Range(match.range(at: 1), in: text) else {
                return nil
            }
            return Int(text[valueRange])
        }
    }

    private static func legacyShadowsocksPort(in value: String) -> Int? {
        guard value.hasPrefix("ss://") else { return nil }
        var payload = String(value.dropFirst("ss://".count))
        if let delimiter = payload.firstIndex(where: {
            $0 == "#" || $0 == "?"
        }) {
            payload = String(payload[..<delimiter])
        }
        payload = payload
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = payload.count % 4
        if remainder != 0 {
            payload += String(repeating: "=", count: 4 - remainder)
        }
        guard let data = Data(base64Encoded: payload),
              let decoded = String(data: data, encoding: .utf8) else {
            return nil
        }
        return endpointPort(in: decoded)
    }

    private static func validateBoundListenerSyntax(
        in text: String,
        lines: [YAMLLine]
    ) throws {
        try validateRootMappingStructure(lines)
        let rootIntegerKeys: Set<String> = [
            "port", "socks-port", "mixed-port", "redir-port", "tproxy-port",
        ]
        for line in lines {
            guard let key = line.rootMappingKey else { continue }
            if rootIntegerKeys.contains(key) {
                guard let port = line.rootIntegerValue,
                      (0...65_535).contains(port) else {
                    throw RuntimeConfigurationComposerError
                        .unsupportedBoundListenerSyntax(key)
                }
            }
            if key == "external-controller" || key == "external-controller-tls" {
                let value = line.rootScalarValue ?? ""
                guard value.isEmpty
                    || value == "null"
                    || value == "~"
                    || endpointPort(in: value) != nil else {
                    throw RuntimeConfigurationComposerError
                        .unsupportedBoundListenerSyntax(key)
                }
            }
            if key == "ss-config" || key == "vmess-config" {
                let value = line.rootScalarValue ?? ""
                guard value.isEmpty
                    || value == "null"
                    || value == "~"
                    || endpointPort(in: value) != nil
                    || (key == "ss-config"
                        && legacyShadowsocksPort(in: value) != nil) else {
                    throw RuntimeConfigurationComposerError
                        .unsupportedBoundListenerSyntax(key)
                }
            }
        }

        for (sectionKey, bindingKey, allowedPattern) in [
            (
                "dns",
                "listen",
                #"(?m)(?:^|[\{,])\s*["']?listen["']?\s*:\s*(?:!!str[ \t]+)?(?:"(?:\[[^\]"\\\r\n]+\]|[^"\\\s,'{}]*):[0-9]{1,5}"|'(?:\[[^\]'\r\n]+\]|[^'\s,{}]*):[0-9]{1,5}'|(?:\[[^\]\s,'"}]+\]|[^\s,'"}]*):[0-9]{1,5})[ \t]*(?=$|#|,|\})"#
            ),
            (
                "tuic-server",
                "listen",
                #"(?m)(?:^|[\{,])\s*["']?listen["']?\s*:\s*(?:!!str[ \t]+)?(?:"(?:\[[^\]"\\\r\n]+\]|[^"\\\s,'{}]*):[0-9]{1,5}"|'(?:\[[^\]'\r\n]+\]|[^'\s,{}]*):[0-9]{1,5}'|(?:\[[^\]\s,'"}]+\]|[^\s,'"}]*):[0-9]{1,5})[ \t]*(?=$|#|,|\})"#
            ),
            (
                "listeners",
                "port",
                #"(?m)(?:^|[\{,])\s*(?:-\s*)?["']?port["']?\s*:\s*(?:!!(?:int|str)[ \t]+)?["']?[0-9][0-9_,/ \t-]*["']?[ \t]*(?=$|#|,|\}|\r?\n)"#
            ),
            (
                "tunnels",
                "address",
                #"(?m)(?:^|[\{,])\s*(?:-\s*)?["']?address["']?\s*:\s*(?:!!str[ \t]+)?["']?(?:\[[^\]]+\]|[^\s,'"}]*):[0-9]{1,5}"#
            ),
        ] {
            if let rootLine = lines.first(where: {
                $0.rootMappingKey == sectionKey
            }), rootLine.rootScalarValue?.hasPrefix("*") == true {
                throw RuntimeConfigurationComposerError
                    .unsupportedBoundListenerSyntax(sectionKey)
            }
            guard let section = rootSection(
                sectionKey,
                in: lines
            ) else {
                continue
            }
            let mergePattern =
                #"(?m)(?:^|[\{,])\s*(?:-\s*)?["']?<<["']?\s*:"#
            if matchCount(mergePattern, in: section) > 0 {
                throw RuntimeConfigurationComposerError
                    .unsupportedBoundListenerSyntax("\(sectionKey).<<")
            }
            if containsUnquotedYAMLAlias(in: section) {
                throw RuntimeConfigurationComposerError
                    .unsupportedBoundListenerSyntax(
                        "\(sectionKey) alias"
                    )
            }
            if containsUnsupportedMappingKeySyntax(in: section) {
                throw RuntimeConfigurationComposerError
                    .unsupportedBoundListenerSyntax(
                        "\(sectionKey) mapping key"
                    )
            }
            if containsIndentedScalarContinuation(
                after: bindingKey,
                in: section
            ) {
                throw RuntimeConfigurationComposerError
                    .unsupportedBoundListenerSyntax(
                        "\(sectionKey).\(bindingKey)"
                    )
            }
            if sectionKey == "tunnels",
               matchCount(#"(?m)^\s*-\s*[>|]"#, in: section) > 0 {
                throw RuntimeConfigurationComposerError
                    .unsupportedBoundListenerSyntax("tunnels compact scalar")
            }
            if sectionKey == "listeners" {
                let ambiguousIntegerPattern =
                    #"(?m)(?:^|[\{,])\s*(?:-\s*)?["']?port["']?\s*:\s*(?:(?:!!int[ \t]+["']?0[0-9_]*[0-9]["']?)|(?:0[0-9_]*[0-9]))[ \t]*(?=$|#|,|\}|\r?\n)"#
                if matchCount(ambiguousIntegerPattern, in: section) > 0 {
                    throw RuntimeConfigurationComposerError
                        .unsupportedBoundListenerSyntax(
                            "listeners.port leading-zero integer"
                        )
                }
            }
            let bindingPattern =
                #"(?m)(?:^|[\{,])\s*(?:-\s*)?["']?"#
                + NSRegularExpression.escapedPattern(for: bindingKey)
                + #"["']?\s*:"#
            guard matchCount(bindingPattern, in: section)
                == matchCount(allowedPattern, in: section) else {
                throw RuntimeConfigurationComposerError
                    .unsupportedBoundListenerSyntax(
                        "\(sectionKey).\(bindingKey)"
                    )
            }
        }
    }

    private static func validateRootMappingStructure(
        _ lines: [YAMLLine]
    ) throws {
        for line in lines where !line.isIndentedContent && !line.isRootTrivia {
            guard line.isRootDocumentStart
                    || line.isRootDocumentEnd
                    || line.isRootDirective
                    || line.rootMappingKey != nil else {
                throw RuntimeConfigurationComposerError
                    .unsupportedBoundListenerSyntax("root mapping")
            }
        }
    }

    private static func containsIndentedScalarContinuation(
        after bindingKey: String,
        in section: String
    ) -> Bool {
        let lines = YAMLLine.split(section)
        let bindingPattern =
            #"^\s*(?:-\s*)?["']?"#
            + NSRegularExpression.escapedPattern(for: bindingKey)
            + #"["']?\s*:"#
        guard let expression = try? NSRegularExpression(
            pattern: bindingPattern
        ) else {
            return true
        }
        for index in lines.indices {
            let line = lines[index]
            let range = NSRange(line.raw.startIndex..<line.raw.endIndex, in: line.raw)
            guard expression.firstMatch(in: line.raw, range: range) != nil else {
                continue
            }
            let indentation = line.raw.prefix {
                $0 == " " || $0 == "\t"
            }.count
            var continuationIndex = index + 1
            while continuationIndex < lines.count,
                  lines[continuationIndex].isYAMLTrivia {
                continuationIndex += 1
            }
            guard continuationIndex < lines.count else { continue }
            let continuation = lines[continuationIndex]
            let continuationIndentation = continuation.raw.prefix {
                $0 == " " || $0 == "\t"
            }.count
            if continuationIndentation > indentation {
                return true
            }
        }
        return false
    }

    private static func containsUnsupportedMappingKeySyntax(
        in text: String
    ) -> Bool {
        for rawLine in YAMLLine.split(text).map(\.raw) {
            var line = yamlContentBeforeComment(rawLine)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("-") {
                line = String(line.dropFirst())
                    .trimmingCharacters(in: .whitespaces)
            }
            if line.hasPrefix("?")
                || line.hasPrefix("!")
                || line.hasPrefix("&") {
                return true
            }
            if let colon = line.firstIndex(of: ":") {
                let keyCandidate = line[..<colon]
                if keyCandidate.contains("\\") {
                    return true
                }
            }
        }

        let flowExplicitKeyPattern =
            #"(?m)(?:^|[\{,])\s*(?:-\s*)?(?:\?\s*|!![A-Za-z0-9:._-]+[ \t]+)(?:["'][^"'\r\n]+["']|[A-Za-z0-9_-]+)\s*:"#
        let flowEscapedKeyPattern =
            #"(?m)(?:^|[\{,])\s*(?:-\s*)?["'][^"'\r\n]*\\[^"'\r\n]*["']\s*:"#
        let flowKeyPropertyPattern =
            #"(?m)(?:^|[\{,])\s*(?:-\s*)?[&!]"#
        return matchCount(flowExplicitKeyPattern, in: text) > 0
            || matchCount(flowEscapedKeyPattern, in: text) > 0
            || matchCount(flowKeyPropertyPattern, in: text) > 0
    }

    private static func containsUnquotedYAMLAlias(in text: String) -> Bool {
        var quote: Character?
        var escaped = false
        var comment = false
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            let next = text.index(after: index)
            if comment {
                if character == "\n" || character == "\r" {
                    comment = false
                }
            } else if escaped {
                escaped = false
            } else if quote == "\"", character == "\\" {
                escaped = true
            } else if let activeQuote = quote {
                if character == activeQuote {
                    if activeQuote == "'",
                       next < text.endIndex,
                       text[next] == "'" {
                        index = text.index(after: next)
                        continue
                    }
                    quote = nil
                }
            } else if character == "\"" || character == "'" {
                quote = character
            } else if character == "#" {
                comment = true
            } else if character == "*",
                      next < text.endIndex,
                      text[next].isLetter || text[next].isNumber
                        || text[next] == "_" || text[next] == "-" {
                return true
            }
            index = next
        }
        return false
    }

    private static func rootSection(
        _ key: String,
        in lines: [YAMLLine]
    ) -> String? {
        guard let index = lines.firstIndex(where: {
            $0.rootMappingKey == key
        }) else {
            return nil
        }
        var end = index + 1
        while end < lines.count {
            let candidate = lines[end]
            if candidate.rootMappingKey != nil
                || candidate.isRootDocumentStart
                || candidate.isRootDocumentEnd
                || candidate.isRootDirective {
                break
            }
            end += 1
        }
        return lines[index..<end].map(\.raw).joined()
    }

    private static func matchCount(_ pattern: String, in text: String) -> Int {
        guard let expression = try? NSRegularExpression(pattern: pattern) else {
            return 0
        }
        return expression.numberOfMatches(
            in: text,
            range: NSRange(text.startIndex..<text.endIndex, in: text)
        )
    }

    private static func endpointPort(in rawValue: String) -> Int? {
        var value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("!!str") {
            value = String(value.dropFirst("!!str".count))
                .trimmingCharacters(in: .whitespaces)
        }
        value = value.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        let pattern =
            #"(?:\[[^\]]+\]|[^:\s]+):([0-9]{1,5})(?:[/?#].*)?$"#
        return capturedPorts(in: value, pattern: pattern).first
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
        try rejectReservedListenerNameConflicts(
            in: section,
            configuration: configuration
        )

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
        try configuration.listenerDescriptors.flatMap { descriptor in
            let fieldPrefix = sequencePrefix + "  "
            var output = [
                "\(sequencePrefix)- name: \(try yamlQuoted(descriptor.name))\(newline)",
                "\(fieldPrefix)type: socks\(newline)",
                "\(fieldPrefix)port: \(descriptor.port)\(newline)",
                "\(fieldPrefix)listen: \(try yamlQuoted(descriptor.host))\(newline)",
                "\(fieldPrefix)udp: true\(newline)",
            ]
            if let outboundProxy = descriptor.outboundProxy {
                output.append(
                    "\(fieldPrefix)proxy: \(try yamlQuoted(outboundProxy))\(newline)"
                )
            }
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
        try configuration.listenerDescriptors.map { descriptor in
            let users: String
            if let authentication = configuration.authentication {
                users = "[{\"username\": \(try yamlQuoted(authentication.username)), "
                    + "\"password\": \(try yamlQuoted(authentication.password))}]"
            } else {
                users = "[]"
            }
            let proxy = try descriptor.outboundProxy.map {
                ", \"proxy\": \(try yamlQuoted($0))"
            } ?? ""
            return "{\"name\": \(try yamlQuoted(descriptor.name)), \"type\": \"socks\", "
                + "\"port\": \(descriptor.port), \"listen\": \(try yamlQuoted(descriptor.host)), "
                + "\"udp\": true\(proxy), \"users\": \(users)}"
        }
    }

    private func rejectReservedListenerNameConflicts(
        in section: String,
        configuration: NetworkExtensionMihomoListenerConfiguration
    ) throws {
        for name in configuration.listenerDescriptors.map(\.name)
        where section.contains(name) {
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
    case unsupportedBoundListenerSyntax(String)
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
        case let .unsupportedBoundListenerSyntax(binding):
            "The listener binding \(binding) uses YAML syntax that MClash cannot safely include in its port-conflict preflight."
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
        var usesStringSemantics = false
        var hasExplicitIntegerTag = false
        if value.hasPrefix("!!int") {
            hasExplicitIntegerTag = true
            value = String(value.dropFirst("!!int".count))
                .trimmingCharacters(in: .whitespaces)
        } else if value.hasPrefix("!!str") {
            usesStringSemantics = true
            value = String(value.dropFirst("!!str".count))
                .trimmingCharacters(in: .whitespaces)
        }
        if value.first == "\"", value.last == "\"", value.count >= 2,
           let decoded = try? JSONDecoder().decode(String.self, from: Data(value.utf8)) {
            usesStringSemantics = !hasExplicitIntegerTag
            value = decoded
        } else if value.first == "'", value.last == "'", value.count >= 2 {
            usesStringSemantics = !hasExplicitIntegerTag
            value = String(value.dropFirst().dropLast())
                .replacingOccurrences(of: "''", with: "'")
        }
        let normalized = value.replacingOccurrences(of: "_", with: "")
        let magnitude = normalized.first == "+" || normalized.first == "-"
            ? String(normalized.dropFirst())
            : normalized
        if !usesStringSemantics,
           magnitude.count > 1,
           magnitude.first == "0" {
            return nil
        }
        return Int(normalized)
    }

    var rootScalarValue: String? {
        guard rootMappingKey != nil,
              let colon = raw.firstIndex(of: ":") else { return nil }
        var value = yamlContentBeforeComment(
            String(raw[raw.index(after: colon)...])
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("!!str") {
            value = String(value.dropFirst("!!str".count))
                .trimmingCharacters(in: .whitespaces)
        }
        if value.first == "\"", value.last == "\"", value.count >= 2,
           let decoded = try? JSONDecoder().decode(
               String.self,
               from: Data(value.utf8)
           ) {
            return decoded
        }
        if value.first == "'", value.last == "'", value.count >= 2 {
            return String(value.dropFirst().dropLast())
                .replacingOccurrences(of: "''", with: "'")
        }
        return value
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
