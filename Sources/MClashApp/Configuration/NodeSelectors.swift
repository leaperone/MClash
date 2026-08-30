import Foundation

/// Identity of a node that survives provider presentation changes and
/// credential rotation.  The connection fingerprint remains useful for
/// diagnostics, but this is the key used to reconcile a refreshed source.
public struct NodeIdentity: Hashable, Codable, Sendable {
    public let fingerprint: String
    public init(node: Node) { self.fingerprint = node.fingerprint }

    /// The stable endpoint identity used for reconciliation. It intentionally
    /// excludes rotating credentials while retaining transport/security
    /// parameters that change where or how the node connects.
    public var endpointFingerprint: String { fingerprint }

    /// Full connection identity, including credentials, for conflict
    /// diagnostics only. Never persist this as the node ID.
    public func connectionFingerprint(for node: Node) -> String {
        Node.makeConnectionFingerprint(
            protocol: node.proto,
            host: node.host,
            port: node.port,
            parameters: node.parameters
        )
    }

    /// Provider credentials are deliberately excluded from identity.  A
    /// subscription may rotate any of these without changing the endpoint a
    /// user selected.  Parameter names are matched case-insensitively because
    /// providers are not consistent about spelling/casing.
    public static let credentialParameterKeys: Set<String> = [
        "uuid", "password", "passwd", "username", "user", "token", "secret",
        "psk", "private-key", "private_key", "privatekey", "client-private-key",
        "client_private_key", "auth", "authentication", "credential"
    ]

    public static func isCredentialParameter(_ key: String) -> Bool {
        credentialParameterKeys.contains(normalizeParameterKey(key))
    }

    /// Presentation metadata is useful for grouping and display, but it does
    /// not describe how a connection reaches its endpoint. Keeping it out of
    /// the identity prevents a provider changing a tag/region from orphaning
    /// a user's fixed node pin.
    public static let presentationParameterKeys: Set<String> = [
        "name", "display-name", "remark", "tag", "tags", "region", "country"
    ]

    public static func isPresentationParameter(_ key: String) -> Bool {
        presentationParameterKeys.contains(normalizeParameterKey(key))
    }

    /// Provider YAML is inconsistent about key casing and underscore versus
    /// hyphen spelling. Identity material uses one canonical representation so
    /// a harmless presentation change does not create a new node ID.
    public static func normalizeParameterKey(_ key: String) -> String {
        key.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "_", with: "-")
    }

    public static func normalizeParameterValue(key: String, value: String) -> String {
        let normalizedKey = normalizeParameterKey(key)
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        switch normalizedKey {
        case "sni", "servername", "server-name", "alpn":
            return trimmed.lowercased()
        default:
            let lowercased = trimmed.lowercased()
            return ["true", "false"].contains(lowercased) ? lowercased : trimmed
        }
    }
}

public enum NodeSelectorCondition: Codable, Hashable, Sendable {
    case nameContains(String)
    case nameEquals(String)
    case hostContains(String)
    case hostEquals(String)
    case ipEquals(String)
    case source(SourceID)
    case protocolIs(NodeProtocol)
    case tagContains(String)

    public func matches(_ node: Node) -> Bool {
        switch self {
        case let .nameContains(value):
            return Self.matchesText(node.userAlias ?? node.displayName, pattern: value)
        case let .nameEquals(value):
            return (node.userAlias ?? node.displayName)
                .compare(value, options: [.caseInsensitive, .diacriticInsensitive])
                == .orderedSame
        case let .hostContains(value):
            return Self.matchesText(node.host, pattern: value)
        case let .hostEquals(value):
            return node.host.lowercased() == normalizeHost(value)
        case let .ipEquals(value):
            return node.host.lowercased() == normalizeHost(value)
        case let .source(id): return node.sourceLinks.contains(id)
        case let .protocolIs(proto): return node.proto == proto
        case let .tagContains(value): return node.tags.contains { Self.matchesText($0, pattern: value) }
        }
    }

    private func normalizeHost(_ value: String) -> String {
        var normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized.first == "[", normalized.last == "]" {
            normalized.removeFirst()
            normalized.removeLast()
        }
        return normalized.trimmingCharacters(in: CharacterSet(charactersIn: "."))
    }

    private static func matchesText(_ text: String, pattern: String) -> Bool {
        let normalizedText = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        let normalizedPattern = pattern.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        guard normalizedPattern.contains("*") || normalizedPattern.contains("?") else {
            return normalizedText.localizedCaseInsensitiveContains(normalizedPattern)
        }
        return wildcardMatch(pattern: Array(normalizedPattern), value: Array(normalizedText))
    }

    private static func wildcardMatch(pattern: [Character], value: [Character]) -> Bool {
        var p = 0
        var v = 0
        var star: Int?
        var starValue = 0
        while v < value.count {
            if p < pattern.count, pattern[p] == "?" || pattern[p] == value[v] {
                p += 1; v += 1
            } else if p < pattern.count, pattern[p] == "*" {
                star = p; p += 1; starValue = v
            } else if let star {
                p = star + 1; starValue += 1; v = starValue
            } else {
                return false
            }
        }
        while p < pattern.count, pattern[p] == "*" { p += 1 }
        return p == pattern.count
    }
}

/// A selector is an AND expression. Multiple selectors on a group are ORed;
/// this makes common policies readable ("US" OR "United States") while
/// retaining an explicit, durable pin for nodes that must never be replaced
/// by a different match. Exclusions apply only to automatic matches; fixed
/// pins remain explicit group members.
public struct NodeSelector: Codable, Hashable, Sendable, Identifiable {
    public let id: UUID
    public var name: String
    public var include: [NodeSelectorCondition]
    public var exclude: [NodeSelectorCondition]
    public var fixedNodeIDs: [NodeID]

    public init(id: UUID = UUID(), name: String = "Selector", include: [NodeSelectorCondition] = [], exclude: [NodeSelectorCondition] = [], fixedNodeIDs: [NodeID] = []) {
        self.id = id; self.name = name; self.include = include; self.exclude = exclude; self.fixedNodeIDs = fixedNodeIDs
    }

    fileprivate func matches(_ node: Node) -> Bool {
        (include.isEmpty || include.allSatisfy { $0.matches(node) }) && !exclude.contains { $0.matches(node) }
    }
}

public struct NodeSelectorResolution: Equatable, Sendable {
    public let nodeIDs: [NodeID]
    public let diagnostics: [ConfigurationDiagnostic]
    public init(nodeIDs: [NodeID], diagnostics: [ConfigurationDiagnostic] = []) {
        self.nodeIDs = nodeIDs; self.diagnostics = diagnostics.sorted { $0.id < $1.id }
    }
}

public enum NodeSelectorResolver {
    /// Resolves selectors deterministically. Pinned members are emitted first
    /// in their persisted order, then dynamic matches are sorted by the
    /// user-facing name, endpoint and stable ID. Missing pins are retained as
    /// diagnostics rather than silently replaced by a different node.
    public static func resolve(selectors: [NodeSelector], nodes: [Node]) -> NodeSelectorResolution {
        guard !selectors.isEmpty else { return NodeSelectorResolution(nodeIDs: []) }
        var byID: [NodeID: Node] = [:]
        var ids: [NodeID] = []
        var seen = Set<NodeID>()
        var diagnostics: [ConfigurationDiagnostic] = []
        let sortedNodes = nodes.sorted(by: stableNodeOrder)
        for node in nodes {
            if byID[node.id] != nil {
                diagnostics.append(.init(
                    severity: .error,
                    code: "duplicate_node_id",
                    subject: node.id.rawValue.uuidString.lowercased(),
                    message: AppLocalization.string(
                        "Node catalog contains more than one record with the same stable node ID."
                    )
                ))
            } else {
                byID[node.id] = node
            }
        }
        for selector in selectors {
            for id in selector.fixedNodeIDs {
                guard byID[id] != nil else {
                    diagnostics.append(.init(
                        severity: .warning,
                        code: "selector_missing_fixed_node",
                        subject: "\(selector.id):\(id.rawValue)",
                        message: AppLocalization.format(
                            "Selector \"%@\" pins a node that is no longer available.",
                            selector.name
                        )
                    ))
                    continue
                }
                // A fixed pin is an explicit user decision. It remains in the
                // resolved group even when a later exclusion would remove it;
                // exclusions only affect automatic matches.
                if seen.insert(id).inserted { ids.append(id) }
            }
            for node in sortedNodes where selector.matches(node)
                && seen.insert(node.id).inserted {
                ids.append(node.id)
            }
        }

        // A stable identity collision means two records claim the same
        // endpoint identity (usually duplicate provider credentials). Keep
        // both visible to the user, but make the ambiguity explicit.
        let collisions = Dictionary(grouping: nodes, by: { NodeIdentity(node: $0).fingerprint })
            .filter { $0.value.count > 1 }
        for (fingerprint, collisionNodes) in collisions {
            let names = collisionNodes.map { $0.userAlias ?? $0.displayName }.sorted().joined(separator: ", ")
            diagnostics.append(.init(
                severity: .warning,
                code: "node_identity_conflict",
                subject: String(fingerprint.prefix(16)),
                message: AppLocalization.format(
                    "Multiple nodes share one stable identity: %@. Review provider credentials or keep one record.",
                    names
                )
            ))
        }
        return NodeSelectorResolution(nodeIDs: ids, diagnostics: diagnostics)
    }

    private static func stableNodeOrder(_ lhs: Node, _ rhs: Node) -> Bool {
        let lk = [(lhs.userAlias ?? lhs.displayName).lowercased(), lhs.host, String(format: "%05d", lhs.port), lhs.id.rawValue.uuidString]
        let rk = [(rhs.userAlias ?? rhs.displayName).lowercased(), rhs.host, String(format: "%05d", rhs.port), rhs.id.rawValue.uuidString]
        return lk.lexicographicallyPrecedes(rk)
    }
}
