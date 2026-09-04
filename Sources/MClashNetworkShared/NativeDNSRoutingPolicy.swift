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

    /// Parses a literal IP nameserver, optionally with a port. Hostnames are
    /// intentionally rejected here because resolving a policy target would
    /// recurse through the very DNS path this policy is selecting.
    public static func literalNameserver(
        _ rawValue: String
    ) -> (address: IPAddress, port: UInt16?)? {
        var value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        var port: UInt16?
        if value.first == "[",
           let closing = value.firstIndex(of: "]") {
            let addressText = String(value[value.index(after: value.startIndex) ..< closing])
            let suffix = String(value[value.index(after: closing)...])
            if suffix.isEmpty {
                value = addressText
            } else {
                guard suffix.first == ":",
                      let parsed = UInt16(suffix.dropFirst()), parsed > 0 else {
                    return nil
                }
                value = addressText
                port = parsed
            }
        } else if value.filter({ $0 == ":" }).count == 1,
                  let separator = value.lastIndex(of: ":") {
            let candidatePort = value[value.index(after: separator)...]
            if let parsed = UInt16(candidatePort), parsed > 0 {
                port = parsed
                value = String(value[..<separator])
            }
        }
        guard let address = try? IPAddress(value) else { return nil }
        return (address, port)
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
        } else if literalNameserver(destination) != nil {
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
