import Foundation

/// Connector-neutral projection of the small, explicit DNS policy subset
/// MClash can safely evaluate natively. Unsupported rule-set/database syntax
/// is retained as `.unsupported` instead of being guessed or treated as a
/// fake-IP/GEO decision.
public struct NativeDNSRoutingPolicy: Sendable, Equatable {
    public enum Decision: Sendable, Equatable {
        case nameserver(String)
        case system
        case unsupported(String)
    }

    private struct Rule: Sendable, Equatable {
        let suffix: String
        let decision: Decision
    }
    private let rules: [Rule]

    public init(rules: [String]) {
        self.rules = rules.compactMap(Self.parse).sorted {
            if $0.suffix.count != $1.suffix.count { return $0.suffix.count > $1.suffix.count }
            return $0.suffix < $1.suffix
        }
    }

    /// Longest suffix wins; ties are stable lexical order. Names are matched
    /// at label boundaries, preventing `badexample.com` matching `example.com`.
    public func decision(for hostname: String) -> Decision {
        let name = Self.normalize(hostname)
        guard !name.isEmpty else { return .system }
        return rules.first(where: { name == $0.suffix || name.hasSuffix("." + $0.suffix) })?.decision ?? .system
    }

    private static func parse(_ raw: String) -> Rule? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        let parts = value.split(separator: ",", maxSplits: 1).map(String.init)
        let matcher = parts[0].lowercased()
        guard matcher.hasPrefix("domain:") || matcher.hasPrefix("domain-suffix:") || matcher.hasPrefix("+") else { return nil }
        let suffix = normalize(String(matcher.split(separator: ":", maxSplits: 1).last ?? Substring(matcher.dropFirst())))
        guard !suffix.isEmpty else { return nil }
        let destination = parts.count == 2 ? parts[1].trimmingCharacters(in: .whitespacesAndNewlines) : "system"
        let decision: Decision
        if destination.isEmpty || destination.caseInsensitiveCompare("system") == .orderedSame || destination.caseInsensitiveCompare("direct") == .orderedSame {
            decision = .system
        } else if destination.contains("/") || (try? IPAddress(destination)) != nil {
            decision = .nameserver(destination)
        } else {
            decision = .unsupported(destination)
        }
        return Rule(suffix: suffix, decision: decision)
    }

    private static func normalize(_ value: String) -> String {
        var result = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        while result.first == "." || result.first == "+" { result.removeFirst() }
        while result.last == "." { result.removeLast() }
        return result
    }
}
