import Foundation
import MClashNetworkShared

enum ProxifierRuleImportError: Error, Equatable, LocalizedError, Sendable {
    case fileTooLarge
    case unsafeXML
    case invalidXML
    case unsupportedDocument
    case unsupportedVersion(String)
    case noRules
    case malformedList
    case cannotAppendRules
    case tooManyCriteria
    case criterionTooLong

    var errorDescription: String? {
        switch self {
        case .fileTooLarge:
            "The Proxifier profile is larger than the 8 MB import limit."
        case .unsafeXML:
            "The Proxifier profile contains a DTD or entity declaration and was not opened."
        case .invalidXML:
            "The selected file is not a valid Proxifier XML profile."
        case .unsupportedDocument:
            "The selected file is not a Proxifier profile."
        case let .unsupportedVersion(version):
            "Proxifier profile version \(version) is not supported."
        case .noRules:
            "The Proxifier profile does not contain any rules."
        case .malformedList:
            "A Proxifier rule contains an unterminated quoted list item."
        case .cannotAppendRules:
            "The imported rules cannot be appended without renumbering the current rule set."
        case .tooManyCriteria:
            "The Proxifier profile contains too many routing criteria to import safely."
        case .criterionTooLong:
            "A Proxifier routing criterion is too long to import safely."
        }
    }
}

struct ProxifierRuleImportItem: Identifiable, Equatable, Sendable {
    let id: Int
    let originalName: String
    let importedName: String
    let originalAction: String
    let criteriaSummary: String
    let rule: CaptureRule?
    let notes: [String]
    let selectedByDefault: Bool
    let isCatchAll: Bool

    var isImportable: Bool { rule != nil }
}

struct ProxifierRuleImportPlan: Identifiable, Equatable, Sendable {
    let id = UUID()
    let sourceName: String
    let profileVersion: String
    let platform: String
    let items: [ProxifierRuleImportItem]
    let notes: [String]

    var importableCount: Int { items.count(where: \.isImportable) }
    var skippedCount: Int { items.count - importableCount }
}

struct ProxifierRuleImporter: Sendable {
    private static let maximumFileSize = 8 * 1_024 * 1_024
    private static let maximumCriteriaTokenCount = 50_000
    private static let maximumMatcherCount = 50_000
    private static let maximumCriteriaTokenLength = 1_024

    private struct ImportBudget {
        var remainingTokens = ProxifierRuleImporter.maximumCriteriaTokenCount
        var remainingMatchers = ProxifierRuleImporter.maximumMatcherCount

        mutating func consumeToken(_ token: String) throws {
            guard token.utf8.count <= ProxifierRuleImporter.maximumCriteriaTokenLength else {
                throw ProxifierRuleImportError.criterionTooLong
            }
            guard remainingTokens > 0 else {
                throw ProxifierRuleImportError.tooManyCriteria
            }
            remainingTokens -= 1
        }

        mutating func consumeMatcher() throws {
            guard remainingMatchers > 0 else {
                throw ProxifierRuleImportError.tooManyCriteria
            }
            remainingMatchers -= 1
        }
    }

    func makePlan(
        data: Data,
        sourceName: String,
        existingRules: [CaptureRule]
    ) throws -> ProxifierRuleImportPlan {
        let document = try parse(data)
        var occupiedNames = Set(existingRules.map { $0.id.lowercased() })
        let maximumPriority = existingRules.map(\.priority).max() ?? 0
        var items: [ProxifierRuleImportItem] = []
        var budget = ImportBudget()
        items.reserveCapacity(document.rules.count)

        for (index, definition) in document.rules.enumerated() {
            let originalName = Self.normalizedRuleName(definition.name)
            let baseName = originalName.isEmpty ? "Imported Rule \(index + 1)" : originalName
            let importedName = uniqueName(baseName, occupiedNames: &occupiedNames)
            let (offset, offsetOverflow) = (index + 1).multipliedReportingOverflow(by: 10)
            guard !offsetOverflow else { throw ProxifierRuleImportError.cannotAppendRules }
            let (priority, priorityOverflow) = maximumPriority.addingReportingOverflow(offset)
            guard !priorityOverflow else { throw ProxifierRuleImportError.cannotAppendRules }
            items.append(try makeItem(
                definition,
                index: index,
                originalName: baseName,
                importedName: importedName,
                priority: priority,
                budget: &budget
            ))
        }

        var notes = [
            "Only routing rules are imported. Proxifier proxy servers, chains, addresses, and credentials are never imported.",
            "Proxy and Chain actions use the current Mihomo profile rules in MClash.",
            "Imported Proxy and Chain rules reject connections while Mihomo is unavailable instead of silently connecting directly.",
        ]
        if document.platform.caseInsensitiveCompare("MacOSX") != .orderedSame {
            notes.append("This profile was created for \(document.platform); review converted rules before importing.")
        }
        return ProxifierRuleImportPlan(
            sourceName: sourceName,
            profileVersion: document.version,
            platform: document.platform,
            items: items,
            notes: notes
        )
    }

    private func parse(_ data: Data) throws -> ProxifierDocument {
        guard data.count <= Self.maximumFileSize else {
            throw ProxifierRuleImportError.fileTooLarge
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw ProxifierRuleImportError.invalidXML
        }
        let lowered = text.lowercased()
        guard !lowered.contains("<!doctype"), !lowered.contains("<!entity") else {
            throw ProxifierRuleImportError.unsafeXML
        }

        let delegate = ProxifierXMLDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.shouldResolveExternalEntities = false
        guard parser.parse(), delegate.parsingError == nil else {
            throw delegate.parsingError ?? ProxifierRuleImportError.invalidXML
        }
        guard delegate.rootName == "ProxifierProfile" else {
            throw ProxifierRuleImportError.unsupportedDocument
        }
        guard ["101", "102"].contains(delegate.version) else {
            throw ProxifierRuleImportError.unsupportedVersion(delegate.version)
        }
        guard !delegate.rules.isEmpty else { throw ProxifierRuleImportError.noRules }
        return ProxifierDocument(
            version: delegate.version,
            platform: delegate.platform.isEmpty ? "Unknown" : delegate.platform,
            rules: delegate.rules
        )
    }

    private func makeItem(
        _ definition: ProxifierRuleDefinition,
        index: Int,
        originalName: String,
        importedName: String,
        priority: Int,
        budget: inout ImportBudget
    ) throws -> ProxifierRuleImportItem {
        let applicationTokens = try Self.splitList(definition.applications, budget: &budget)
        let targetTokens = try Self.splitList(definition.targets, budget: &budget)
        let portTokens = try Self.splitList(definition.ports, budget: &budget)
        var notes: [String] = []
        var hasLossyCriteria = false

        var sources: [SourceMatcher] = []
        var seenSources: Set<SourceMatcher> = []
        for token in applicationTokens {
            do {
                let matcher = try ApplicationIdentifierPatternMatcher(pattern: token)
                let source = SourceMatcher.applicationIdentifierPattern(matcher)
                if seenSources.insert(source).inserted {
                    try budget.consumeMatcher()
                    sources.append(source)
                }
            } catch let error as ProxifierRuleImportError where error == .tooManyCriteria {
                throw error
            } catch {
                hasLossyCriteria = true
                notes.append("Application mask \(Self.safeTokenDescription(token)) is unsupported.")
            }
        }
        if !applicationTokens.isEmpty && sources.isEmpty {
            return unsupportedItem(
                index: index,
                originalName: originalName,
                importedName: importedName,
                action: definition.actionType,
                criteria: criteriaSummary(applications: applicationTokens, targets: targetTokens, ports: portTokens),
                notes: notes + ["No application condition could be converted safely."]
            )
        }

        var destinations: [DestinationMatcher] = []
        var seenDestinations: Set<DestinationMatcher> = []
        for token in targetTokens {
            do {
                guard let matcher = try destinationMatcher(token) else {
                    hasLossyCriteria = true
                    notes.append("Dynamic target \(Self.safeTokenDescription(token)) was skipped.")
                    continue
                }
                if seenDestinations.insert(matcher).inserted {
                    try budget.consumeMatcher()
                    destinations.append(matcher)
                }
            } catch let error as ProxifierRuleImportError where error == .tooManyCriteria {
                throw error
            } catch {
                hasLossyCriteria = true
                notes.append("Target \(Self.safeTokenDescription(token)) is unsupported.")
            }
        }
        if !targetTokens.isEmpty && destinations.isEmpty {
            return unsupportedItem(
                index: index,
                originalName: originalName,
                importedName: importedName,
                action: definition.actionType,
                criteria: criteriaSummary(applications: applicationTokens, targets: targetTokens, ports: portTokens),
                notes: notes + ["No destination condition could be converted safely."]
            )
        }

        var portRanges: [PortRange] = []
        var seenPortRanges: Set<PortRange> = []
        for token in portTokens {
            do {
                let range = try portRange(token)
                if seenPortRanges.insert(range).inserted {
                    try budget.consumeMatcher()
                    portRanges.append(range)
                }
            } catch let error as ProxifierRuleImportError where error == .tooManyCriteria {
                throw error
            } catch {
                hasLossyCriteria = true
                notes.append("Port \(Self.safeTokenDescription(token)) is unsupported.")
            }
        }
        if !portTokens.isEmpty && portRanges.isEmpty {
            return unsupportedItem(
                index: index,
                originalName: originalName,
                importedName: importedName,
                action: definition.actionType,
                criteria: criteriaSummary(applications: applicationTokens, targets: targetTokens, ports: portTokens),
                notes: notes + ["No port condition could be converted safely."]
            )
        }

        let action: CaptureAction
        switch definition.actionType.lowercased() {
        case "direct":
            action = .direct
        case "block", "reject":
            action = .reject
        case "proxy", "chain":
            action = .mihomo(.profileRules)
            notes.append("Converted from Proxifier \(definition.actionType) to Mihomo profile rules.")
        default:
            return unsupportedItem(
                index: index,
                originalName: originalName,
                importedName: importedName,
                action: definition.actionType,
                criteria: criteriaSummary(applications: applicationTokens, targets: targetTokens, ports: portTokens),
                notes: notes + ["The action is not supported by MClash."]
            )
        }

        let isCatchAll = sources.isEmpty && destinations.isEmpty && portRanges.isEmpty
        if isCatchAll, action == .direct {
            return unsupportedItem(
                index: index,
                originalName: originalName,
                importedName: importedName,
                action: definition.actionType,
                criteria: "All TCP traffic",
                notes: notes + ["Skipped because MClash already uses Direct when no rule matches."]
            )
        }
        if isCatchAll {
            notes.append("Catch-all rule: enabling it affects all non-safety-bypass TCP traffic.")
        }

        do {
            let rule = try CaptureRule(
                id: importedName,
                enabled: definition.enabled,
                priority: priority,
                sources: sources,
                destinations: destinations,
                protocols: [.tcp],
                portRanges: portRanges,
                action: action,
                unavailableFallback: unavailableFallback(for: action)
            )
            return ProxifierRuleImportItem(
                id: index,
                originalName: originalName,
                importedName: importedName,
                originalAction: definition.actionType,
                criteriaSummary: criteriaSummary(
                    applications: applicationTokens,
                    targets: targetTokens,
                    ports: portTokens
                ),
                rule: rule,
                notes: notes,
                selectedByDefault: !isCatchAll && !hasLossyCriteria,
                isCatchAll: isCatchAll
            )
        } catch {
            return unsupportedItem(
                index: index,
                originalName: originalName,
                importedName: importedName,
                action: definition.actionType,
                criteria: criteriaSummary(applications: applicationTokens, targets: targetTokens, ports: portTokens),
                notes: notes + ["The converted rule did not pass MClash validation."]
            )
        }
    }

    private func unsupportedItem(
        index: Int,
        originalName: String,
        importedName: String,
        action: String,
        criteria: String,
        notes: [String]
    ) -> ProxifierRuleImportItem {
        ProxifierRuleImportItem(
            id: index,
            originalName: originalName,
            importedName: importedName,
            originalAction: action,
            criteriaSummary: criteria,
            rule: nil,
            notes: notes,
            selectedByDefault: false,
            isCatchAll: false
        )
    }

    private func destinationMatcher(_ token: String) throws -> DestinationMatcher? {
        let value = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        if value.hasPrefix("%"), value.hasSuffix("%") { return nil }
        if value.contains("/") {
            return .network(try IPNetwork(value))
        }
        if let address = try? IPAddress(value) {
            return .ip(address)
        }
        if Self.looksLikeIPAddressRange(value) {
            throw ProxifierRuleImportError.invalidXML
        }
        if Self.looksLikeIPv4Mask(value) {
            guard let network = try ipv4WildcardNetwork(value) else {
                throw ProxifierRuleImportError.invalidXML
            }
            return .network(network)
        }
        if value.contains("*") || value.contains("?") {
            return .hostPattern(try HostPatternMatcher(pattern: value))
        }
        return .host(try HostMatcher(kind: .exact, value: value))
    }

    private func ipv4WildcardNetwork(_ value: String) throws -> IPNetwork? {
        guard value.contains("*") else { return nil }
        var components = value.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard (1 ... 4).contains(components.count) else { return nil }
        while components.count < 4 { components.append("*") }
        guard let firstWildcard = components.firstIndex(of: "*"),
              components[firstWildcard...].allSatisfy({ $0 == "*" }),
              components[..<firstWildcard].allSatisfy({
                  guard let octet = UInt8($0) else { return false }
                  return String(octet) == $0 || $0 == "0"
              }) else { return nil }
        let address = components.map { $0 == "*" ? "0" : $0 }.joined(separator: ".")
        return try IPNetwork("\(address)/\(firstWildcard * 8)")
    }

    private func portRange(_ token: String) throws -> PortRange {
        let bounds = token.split(separator: "-", omittingEmptySubsequences: false)
        guard (1 ... 2).contains(bounds.count),
              let lower = UInt16(bounds[0].trimmingCharacters(in: .whitespaces)),
              lower > 0 else { throw ProxifierRuleImportError.invalidXML }
        let upper: UInt16
        if bounds.count == 2 {
            guard let value = UInt16(bounds[1].trimmingCharacters(in: .whitespaces)),
                  value >= lower else { throw ProxifierRuleImportError.invalidXML }
            upper = value
        } else {
            upper = lower
        }
        return try PortRange(lowerBound: lower, upperBound: upper)
    }

    private func criteriaSummary(
        applications: [String],
        targets: [String],
        ports: [String]
    ) -> String {
        var parts: [String] = []
        if !applications.isEmpty { parts.append("\(applications.count) app masks") }
        if !targets.isEmpty { parts.append("\(targets.count) targets") }
        if !ports.isEmpty { parts.append("\(ports.count) port ranges") }
        return parts.isEmpty ? "All TCP traffic" : parts.joined(separator: " · ")
    }

    private func unavailableFallback(for action: CaptureAction) -> UnavailableFallback {
        if case .mihomo = action { return .reject }
        return .direct
    }

    private func uniqueName(_ base: String, occupiedNames: inout Set<String>) -> String {
        let cleaned = Self.utf8Prefix(base, maximumLength: 255)
        if occupiedNames.insert(cleaned.lowercased()).inserted { return cleaned }
        var suffix = 2
        while true {
            let marker = " \(suffix)"
            let candidate = Self.utf8Prefix(
                cleaned,
                maximumLength: max(1, 255 - marker.utf8.count)
            ) + marker
            if occupiedNames.insert(candidate.lowercased()).inserted { return candidate }
            suffix += 1
        }
    }

    private static func splitList(
        _ value: String,
        budget: inout ImportBudget
    ) throws -> [String] {
        var result: [String] = []
        var current = ""
        var quoted = false
        for character in value {
            if character == "\"" {
                quoted.toggle()
            } else if character == ";", !quoted {
                try appendToken(current, to: &result, budget: &budget)
                current = ""
            } else {
                current.append(character)
            }
        }
        guard !quoted else { throw ProxifierRuleImportError.malformedList }
        try appendToken(current, to: &result, budget: &budget)
        return result
    }

    private static func appendToken(
        _ value: String,
        to result: inout [String],
        budget: inout ImportBudget
    ) throws {
        let token = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { return }
        try budget.consumeToken(token)
        result.append(token)
    }

    private static func normalizedRuleName(_ value: String) -> String {
        let disallowed = CharacterSet.controlCharacters
            .union(.newlines)
            .union(.illegalCharacters)
        let sanitized = value.unicodeScalars.map { scalar in
            disallowed.contains(scalar) ? " " : String(scalar)
        }.joined()
        return sanitized.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static func utf8Prefix(_ value: String, maximumLength: Int) -> String {
        var result = ""
        var byteCount = 0
        for character in value {
            let encodedLength = String(character).utf8.count
            guard byteCount + encodedLength <= maximumLength else { break }
            result.append(character)
            byteCount += encodedLength
        }
        return result
    }

    private static func looksLikeIPAddressRange(_ value: String) -> Bool {
        let components = value.split(separator: "-", omittingEmptySubsequences: false)
        guard components.count == 2 else { return false }
        let lower = String(components[0]).trimmingCharacters(in: .whitespaces)
        let upper = String(components[1]).trimmingCharacters(in: .whitespaces)
        guard (try? IPAddress(lower)) != nil else { return false }
        if (try? IPAddress(upper)) != nil { return true }
        return !upper.isEmpty && upper.allSatisfy { character in
            character.isNumber || character == "." || character == ":"
        }
    }

    private static func looksLikeIPv4Mask(_ value: String) -> Bool {
        guard value.contains("*") else { return false }
        let components = value.split(separator: ".", omittingEmptySubsequences: false)
        guard (1 ... 4).contains(components.count) else { return false }
        return components.allSatisfy { component in
            component == "*" || (!component.isEmpty && component.allSatisfy(\.isNumber))
        }
    }

    private static func safeTokenDescription(_ token: String) -> String {
        let redacted = token.count > 48 ? String(token.prefix(45)) + "…" : token
        return "“\(redacted)”"
    }
}

private struct ProxifierDocument: Sendable {
    let version: String
    let platform: String
    let rules: [ProxifierRuleDefinition]
}

private struct ProxifierRuleDefinition: Sendable {
    let enabled: Bool
    let name: String
    let applications: String
    let targets: String
    let ports: String
    let actionType: String
}

private final class ProxifierXMLDelegate: NSObject, XMLParserDelegate {
    private struct RuleBuilder {
        var enabled = true
        var name = ""
        var applications = ""
        var targets = ""
        var ports = ""
        var actionType = ""
    }

    private(set) var rootName = ""
    private(set) var version = ""
    private(set) var platform = ""
    private(set) var rules: [ProxifierRuleDefinition] = []
    private(set) var parsingError: ProxifierRuleImportError?
    private var depth = 0
    private var inRuleList = false
    private var ruleListDepth = 0
    private var currentRule: RuleBuilder?
    private var currentRuleDepth = 0
    private var currentField: String?
    private var fieldText = ""

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        depth += 1
        guard depth <= 64 else {
            fail(parser, with: .invalidXML)
            return
        }
        if depth == 1 {
            rootName = elementName
            version = attributeDict["version"] ?? ""
            platform = attributeDict["platform"] ?? ""
        }
        if elementName == "RuleList" {
            inRuleList = true
            ruleListDepth = depth
            return
        }
        if inRuleList, elementName == "Rule", currentRule == nil {
            guard rules.count < 10_000 else {
                fail(parser, with: .invalidXML)
                return
            }
            currentRule = RuleBuilder(
                enabled: (attributeDict["enabled"] ?? "true").lowercased() != "false"
            )
            currentRuleDepth = depth
            return
        }
        guard currentRule != nil, depth == currentRuleDepth + 1,
              ["Name", "Applications", "Targets", "Ports", "Action"].contains(elementName)
        else { return }
        currentField = elementName
        fieldText = ""
        if elementName == "Action" {
            currentRule?.actionType = attributeDict["type"] ?? ""
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard currentField != nil else { return }
        guard fieldText.utf8.count + string.utf8.count <= 4 * 1_024 * 1_024 else {
            fail(parser, with: .invalidXML)
            return
        }
        fieldText.append(string)
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        defer { depth -= 1 }
        if let field = currentField, elementName == field, depth == currentRuleDepth + 1 {
            switch field {
            case "Name": currentRule?.name = fieldText
            case "Applications": currentRule?.applications = fieldText
            case "Targets": currentRule?.targets = fieldText
            case "Ports": currentRule?.ports = fieldText
            default: break
            }
            currentField = nil
            fieldText = ""
            return
        }
        if elementName == "Rule", depth == currentRuleDepth, let rule = currentRule {
            rules.append(ProxifierRuleDefinition(
                enabled: rule.enabled,
                name: rule.name,
                applications: rule.applications,
                targets: rule.targets,
                ports: rule.ports,
                actionType: rule.actionType
            ))
            currentRule = nil
            return
        }
        if elementName == "RuleList", depth == ruleListDepth {
            inRuleList = false
        }
    }

    func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) {
        if parsingError == nil { parsingError = .invalidXML }
    }

    func parser(
        _ parser: XMLParser,
        resolveExternalEntityName name: String,
        systemID: String?
    ) -> Data? {
        parsingError = .unsafeXML
        parser.abortParsing()
        return nil
    }

    private func fail(_ parser: XMLParser, with error: ProxifierRuleImportError) {
        parsingError = error
        parser.abortParsing()
    }
}
