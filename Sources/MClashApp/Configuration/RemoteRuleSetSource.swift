import Foundation
import MClashNetworkShared

public enum RemoteRuleSetRefreshState: String, Codable, Sendable {
    case updated
    case notModified
}

public struct RemoteRuleSetRefreshResult: Equatable, Sendable {
    public let ruleSet: RuleSet
    public let state: RemoteRuleSetRefreshState
    public let checkedAt: Date
    public let lastUpdated: Date?

    public init(ruleSet: RuleSet, state: RemoteRuleSetRefreshState, checkedAt: Date, lastUpdated: Date?) {
        self.ruleSet = ruleSet
        self.state = state
        self.checkedAt = checkedAt
        self.lastUpdated = lastUpdated
    }
}

public struct RemoteRuleSetCacheMetadata: Equatable, Sendable {
    public let checkedAt: Date
    public let lastUpdated: Date?
    public let revision: Int

    public init(checkedAt: Date, lastUpdated: Date?, revision: Int) {
        self.checkedAt = checkedAt
        self.lastUpdated = lastUpdated
        self.revision = revision
    }
}

public enum RemoteRuleSetError: Error, Equatable, Sendable {
    case missingSourceURL
    case unsupportedSourceScheme
    case sourceCredentialsNotAllowed
    case unsupportedFormat
    case invalidRulePayload
    case responseTooLarge(Int)
    case unexpectedHTTPStatus(Int)
    case downloadFailed
    case validationFailed
    case emptyPayload
    case invalidEncoding
    case invalidYAML
    case tooManyLines(Int)
    case tooManyRules(Int)
    case noCachedRuleSet
    case cacheSourceMismatch
    case alreadyRefreshing
}

extension RemoteRuleSetError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .missingSourceURL: AppLocalization.string("The rule set does not have a source URL.")
        case .unsupportedSourceScheme: AppLocalization.string("Rule set sources must use HTTP or HTTPS.")
        case .sourceCredentialsNotAllowed: AppLocalization.string("Rule set source URLs cannot contain credentials.")
        case .unsupportedFormat: AppLocalization.string("MRS rule sets are not supported by the Xray renderer.")
        case .invalidRulePayload: AppLocalization.string("The rule set contains an unsupported or invalid rule.")
        case let .responseTooLarge(limit): AppLocalization.format("The rule set response exceeded the %@-byte limit.", AppLocalization.number(limit))
        case let .unexpectedHTTPStatus(status): AppLocalization.format("The rule set server returned HTTP %@.", AppLocalization.number(status))
        case .downloadFailed: AppLocalization.string("The rule set could not be downloaded.")
        case .validationFailed: AppLocalization.string("The refreshed rule set failed runtime validation.")
        case .emptyPayload: AppLocalization.string("The rule set did not contain any rules.")
        case .invalidEncoding: AppLocalization.string("The rule set is not valid UTF-8.")
        case .invalidYAML: AppLocalization.string("The rule set YAML payload is invalid.")
        case let .tooManyLines(limit): AppLocalization.format("The rule set exceeded the %@-line limit.", AppLocalization.number(limit))
        case let .tooManyRules(limit): AppLocalization.format("The rule set exceeded the %@-rule limit.", AppLocalization.number(limit))
        case .noCachedRuleSet: AppLocalization.string("No last-known-good rule set is available.")
        case .cacheSourceMismatch: AppLocalization.string("The cached rule set belongs to a different source URL.")
        case .alreadyRefreshing: AppLocalization.string("This rule set is already being updated.")
        }
    }
}

/// Fetches and caches only the rules declared by a MClash-owned RuleSet.
/// Remote payloads never alter groups, DNS, entrances, or rule-set actions.
public actor RemoteRuleSetSource {
    public static let defaultMaximumBytes = 2 * 1024 * 1024
    public static let defaultMaximumLines = 16_384
    public static let defaultMaximumRules = 16_384

    private struct CacheEnvelope: Codable, Sendable {
        let sourceURL: String
        let eTag: String?
        let lastModified: String?
        let rules: [String]
        let revision: Int
        let checkedAt: Date
        let lastUpdated: Date?
        let behavior: String
        let format: String
    }

    private let cacheDirectory: URL
    private let downloader: any SubscriptionDownloading
    private let replacer: AtomicFileReplacer
    private let maximumBytes: Int
    private let maximumLines: Int
    private let maximumRules: Int
    private let fileManager: FileManager
    private var activeRefreshes: Set<RuleSetID> = []

    public init(
        cacheDirectory: URL,
        downloader: (any SubscriptionDownloading)? = nil,
        replacer: AtomicFileReplacer = AtomicFileReplacer(),
        maximumBytes: Int = RemoteRuleSetSource.defaultMaximumBytes,
        maximumLines: Int = RemoteRuleSetSource.defaultMaximumLines,
        maximumRules: Int = RemoteRuleSetSource.defaultMaximumRules,
        fileManager: FileManager = .default
    ) {
        self.cacheDirectory = cacheDirectory.standardizedFileURL
        self.downloader = downloader ?? URLSessionSubscriptionDownloader(maximumResponseSize: maximumBytes)
        self.replacer = replacer
        self.maximumBytes = maximumBytes
        self.maximumLines = maximumLines
        self.maximumRules = maximumRules
        self.fileManager = fileManager
    }

    public func refresh(
        _ ruleSet: RuleSet,
        now: Date = Date(),
        validate: (@Sendable ([String]) async throws -> Void)? = nil
    ) async throws -> RemoteRuleSetRefreshResult {
        guard activeRefreshes.insert(ruleSet.id).inserted else { throw RemoteRuleSetError.alreadyRefreshing }
        defer { activeRefreshes.remove(ruleSet.id) }
        let sourceURL = try Self.validatedURL(ruleSet.sourceURL)
        guard ruleSet.format != .mrs else { throw RemoteRuleSetError.unsupportedFormat }
        // A changed URL is a new source identity. Ignore the old validators and
        // cache for this refresh; loadCached still rejects that cache explicitly.
        let cached: CacheEnvelope?
        do {
            cached = try loadEnvelope(for: ruleSet, sourceURL: sourceURL)
        } catch RemoteRuleSetError.cacheSourceMismatch {
            cached = nil
        }
        var request = URLRequest(url: sourceURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.setValue("MClash/1.6", forHTTPHeaderField: "User-Agent")
        request.setValue("application/yaml, text/yaml, text/plain", forHTTPHeaderField: "Accept")
        if let eTag = cached?.eTag { request.setValue(eTag, forHTTPHeaderField: "If-None-Match") }
        if let lastModified = cached?.lastModified { request.setValue(lastModified, forHTTPHeaderField: "If-Modified-Since") }

        let response: SubscriptionDownloadResponse
        do {
            response = try await downloader.download(request)
            try Task.checkCancellation()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw RemoteRuleSetError.downloadFailed
        }
        if response.statusCode == 304 {
            guard let cached else { throw RemoteRuleSetError.noCachedRuleSet }
            try await validateRuntime(cached.rules, using: validate)
            let refreshedCache = CacheEnvelope(
                sourceURL: sourceURL.absoluteString, eTag: response.eTag ?? cached.eTag,
                lastModified: response.lastModified ?? cached.lastModified, rules: cached.rules,
                revision: cached.revision, checkedAt: now, lastUpdated: cached.lastUpdated,
                behavior: ruleSet.behavior.rawValue, format: ruleSet.format.rawValue
            )
            try await write(refreshedCache, for: ruleSet)
            return RemoteRuleSetRefreshResult(
                ruleSet: ruleSetWithRules(ruleSet, cached.rules, revision: max(ruleSet.revision, cached.revision)),
                state: .notModified, checkedAt: now, lastUpdated: cached.lastUpdated
            )
        }
        guard (200..<300).contains(response.statusCode) else {
            throw RemoteRuleSetError.unexpectedHTTPStatus(response.statusCode)
        }
        guard let data = response.data, !data.isEmpty else { throw RemoteRuleSetError.emptyPayload }
        guard data.count <= maximumBytes else { throw RemoteRuleSetError.responseTooLarge(maximumBytes) }
        let rules = try RemoteRuleSetPayloadParser(
            maximumLines: maximumLines,
            maximumRules: maximumRules
        ).parse(data, format: ruleSet.format, behavior: ruleSet.behavior)
        try await validateRuntime(rules, using: validate)
        let nextRevision = max(ruleSet.revision, cached?.revision ?? 0) + 1
        let envelope = CacheEnvelope(
            sourceURL: sourceURL.absoluteString,
            eTag: response.eTag,
            lastModified: response.lastModified,
            rules: rules,
            revision: nextRevision, checkedAt: now, lastUpdated: now,
            behavior: ruleSet.behavior.rawValue, format: ruleSet.format.rawValue
        )
        try await write(envelope, for: ruleSet)
        return RemoteRuleSetRefreshResult(
            ruleSet: ruleSetWithRules(ruleSet, rules, revision: nextRevision),
            state: .updated, checkedAt: now, lastUpdated: now
        )
    }

    public func loadCached(_ ruleSet: RuleSet) throws -> RuleSet {
        let sourceURL = try Self.validatedURL(ruleSet.sourceURL)
        guard let cached = try loadEnvelope(for: ruleSet, sourceURL: sourceURL) else {
            throw RemoteRuleSetError.noCachedRuleSet
        }
        return ruleSetWithRules(ruleSet, cached.rules, revision: max(ruleSet.revision, cached.revision))
    }

    private func validateRuntime(_ rules: [String], using validate: (@Sendable ([String]) async throws -> Void)?) async throws {
        do {
            try Task.checkCancellation()
            try await validate?(rules)
            try Task.checkCancellation()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw RemoteRuleSetError.validationFailed
        }
    }

    public func cachedMetadata(for ruleSet: RuleSet) throws -> RemoteRuleSetCacheMetadata? {
        let sourceURL = try Self.validatedURL(ruleSet.sourceURL)
        guard let cached = try loadEnvelope(for: ruleSet, sourceURL: sourceURL) else { return nil }
        return RemoteRuleSetCacheMetadata(checkedAt: cached.checkedAt, lastUpdated: cached.lastUpdated, revision: cached.revision)
    }

    private func loadEnvelope(for ruleSet: RuleSet, sourceURL: URL) throws -> CacheEnvelope? {
        let url = cacheURL(for: ruleSet)
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber,
              size.intValue <= maximumBytes * 2 else { return nil }
        let envelope: CacheEnvelope
        do {
            envelope = try JSONDecoder().decode(CacheEnvelope.self, from: Data(contentsOf: url))
        } catch {
            return nil
        }
        guard envelope.sourceURL == sourceURL.absoluteString else { throw RemoteRuleSetError.cacheSourceMismatch }
        guard envelope.behavior == ruleSet.behavior.rawValue, envelope.format == ruleSet.format.rawValue else {
            throw RemoteRuleSetError.cacheSourceMismatch
        }
        guard !envelope.rules.isEmpty, envelope.rules.count <= maximumRules,
              (try? RemoteRuleSetPayloadParser(maximumLines: maximumLines, maximumRules: maximumRules)
                .validate(envelope.rules, behavior: ruleSet.behavior)) != nil else { return nil }
        return envelope
    }

    private func write(_ envelope: CacheEnvelope, for ruleSet: RuleSet) async throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(envelope)
        let staged = try await replacer.stage(data: data, in: cacheDirectory, preferredName: "rule-set-\(ruleSet.id.rawValue.uuidString).json")
        let receipt: FileReplacementReceipt
        do {
            receipt = try await replacer.replace(destinationURL: cacheURL(for: ruleSet), withStagedFile: staged)
            try await replacer.commit(receipt)
        } catch {
            try? fileManager.removeItem(at: staged)
            throw error
        }
    }

    private func cacheURL(for ruleSet: RuleSet) -> URL {
        cacheDirectory.appendingPathComponent("rule-set-\(ruleSet.id.rawValue.uuidString).json", isDirectory: false)
    }

    private func ruleSetWithRules(_ ruleSet: RuleSet, _ rules: [String], revision: Int) -> RuleSet {
        RuleSet(id: ruleSet.id, name: ruleSet.name, sourceURL: ruleSet.sourceURL, rules: rules,
                defaultAction: ruleSet.defaultAction, behavior: ruleSet.behavior, format: ruleSet.format,
                path: ruleSet.path, enabled: ruleSet.enabled, revision: revision)
    }

    private static func validatedURL(_ value: URL?) throws -> URL {
        guard let value else { throw RemoteRuleSetError.missingSourceURL }
        guard let scheme = value.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            throw RemoteRuleSetError.unsupportedSourceScheme
        }
        guard value.host != nil else { throw RemoteRuleSetError.missingSourceURL }
        guard value.user == nil && value.password == nil else { throw RemoteRuleSetError.sourceCredentialsNotAllowed }
        return value
    }
}

private struct RemoteRuleSetPayloadParser: Sendable {
    let maximumLines: Int
    let maximumRules: Int

    func parse(_ data: Data, format: RuleSetFormat, behavior: RuleSetBehavior) throws -> [String] {
        guard let text = String(data: data, encoding: .utf8) else { throw RemoteRuleSetError.invalidEncoding }
        let lines = text.components(separatedBy: .newlines)
        guard lines.count <= maximumLines else { throw RemoteRuleSetError.tooManyLines(maximumLines) }
        let rules: [String]
        switch format {
        case .text: rules = textRules(lines)
        case .yaml: rules = try yamlRules(lines)
        case .mrs: throw RemoteRuleSetError.unsupportedFormat
        }
        guard !rules.isEmpty else { throw RemoteRuleSetError.emptyPayload }
        guard rules.count <= maximumRules else { throw RemoteRuleSetError.tooManyRules(maximumRules) }
        try validate(rules, behavior: behavior)
        return rules
    }

    fileprivate func validate(_ rules: [String], behavior: RuleSetBehavior) throws {
        for rule in rules {
            switch behavior {
            case .domain:
                guard validDomain(rule) else { throw RemoteRuleSetError.invalidRulePayload }
            case .ipcidr:
                guard (try? IPNetwork(rule)) != nil else { throw RemoteRuleSetError.invalidRulePayload }
            case .classical:
                try validateClassical(rule)
            }
        }
    }

    private func validDomain(_ value: String) -> Bool {
        let value = value.hasPrefix("+.") ? String(value.dropFirst(2)) : value
        guard !value.isEmpty, !value.contains(".."), !value.contains(where: { $0.isWhitespace }),
              value.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == "*" }),
              !value.hasPrefix("."), !value.hasSuffix(".") else { return false }
        return value.split(separator: ".").allSatisfy { !$0.isEmpty && $0.first != "-" && $0.last != "-" }
    }

    private func validateClassical(_ value: String) throws {
        let parts = value.split(separator: ",", omittingEmptySubsequences: false).map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        guard (2 ... 3).contains(parts.count), !parts[1].isEmpty else {
            throw RemoteRuleSetError.invalidRulePayload
        }
        guard parts.count == 2 || parts[2].lowercased() == "no-resolve" else {
            throw RemoteRuleSetError.invalidRulePayload
        }
        switch parts[0].uppercased() {
        case "DOMAIN", "DOMAIN-SUFFIX", "DOMAIN-WILDCARD":
            guard validDomain(parts[1]) else { throw RemoteRuleSetError.invalidRulePayload }
        case "IP-CIDR", "IP-CIDR6":
            guard (try? IPNetwork(parts[1])) != nil else { throw RemoteRuleSetError.invalidRulePayload }
        case "GEOIP", "GEOSITE":
            guard parts[1].allSatisfy({ !$0.isWhitespace && $0 != "," }) else { throw RemoteRuleSetError.invalidRulePayload }
        case "DST-PORT":
            guard let port = Int(parts[1]), (1 ... 65_535).contains(port) else { throw RemoteRuleSetError.invalidRulePayload }
        case "NETWORK":
            guard ["tcp", "udp"].contains(parts[1].lowercased()) else { throw RemoteRuleSetError.invalidRulePayload }
        default:
            throw RemoteRuleSetError.invalidRulePayload
        }
    }

    private func textRules(_ lines: [String]) -> [String] {
        lines.compactMap { line in
            let value = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty, !value.hasPrefix("#"), !value.hasPrefix("//") else { return nil }
            return value
        }
    }

    private func yamlRules(_ lines: [String]) throws -> [String] {
        var listKey: String?
        var listIndent = -1
        var rules: [String] = []
        for rawLine in lines {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            if line == "---" || line == "..." { continue }
            let indent = rawLine.prefix(while: { $0 == " " || $0 == "\t" }).count
            if indent == 0, line.hasSuffix(":") {
                let key = String(line.dropLast()).trimmingCharacters(in: .whitespaces)
                guard key == "payload" || key == "rules", listKey == nil else {
                    throw RemoteRuleSetError.invalidYAML
                }
                listKey = key
                listIndent = indent
                continue
            }
            guard line.hasPrefix("-") else {
                throw RemoteRuleSetError.invalidYAML
            }
            guard listKey != nil, indent > listIndent else { throw RemoteRuleSetError.invalidYAML }
            let value = stripComment(String(line.dropFirst()).trimmingCharacters(in: .whitespaces))
            guard let normalized = yamlScalar(String(value)), !normalized.isEmpty else {
                throw RemoteRuleSetError.invalidYAML
            }
            rules.append(normalized)
        }
        return rules
    }

    private func yamlScalar(_ value: String) -> String? {
        guard !value.hasPrefix("#") else { return nil }
        if value.count >= 2, (value.first == "\"" && value.last == "\"") || (value.first == "'" && value.last == "'") {
            return String(value.dropFirst().dropLast())
        }
        return value
    }

    private func stripComment(_ value: String) -> String {
        var quoted = false
        var escaped = false
        for index in value.indices {
            let character = value[index]
            if character == "\\", quoted {
                escaped.toggle()
                continue
            }
            if character == "\"" || character == "'", !escaped {
                quoted.toggle()
            }
            if character == "#", !quoted,
               index == value.startIndex || value[value.index(before: index)].isWhitespace {
                return String(value[..<index]).trimmingCharacters(in: .whitespaces)
            }
            escaped = false
        }
        return value
    }
}
