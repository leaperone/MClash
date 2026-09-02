import Foundation

/// Maps the two everyday split-traffic paths onto existing configuration
/// objects. No extra runtime: a source-scoped node group plus one listener or
/// a handful of application rules.
enum ConfigurationSplitPaths {
    enum Role: String, Sendable {
        case browser
        case apps
    }

    struct BrowserPath: Equatable, Sendable {
        var enabled: Bool
        var kind: EntranceKind
        var bindAddress: String
        var port: Int
        var sourceID: SourceID?

        var address: String { "\(bindAddress):\(port)" }
    }

    struct AppPath: Equatable, Sendable {
        var enabled: Bool
        var sourceID: SourceID?
        var applicationPatterns: [String]
    }

    enum Error: Swift.Error, Equatable, LocalizedError {
        case workspaceMissing
        case invalidPort
        case invalidKind
        case sourceMissing

        var errorDescription: String? {
            switch self {
            case .workspaceMissing:
                AppLocalization.string("Create a configuration before setting traffic paths.")
            case .invalidPort:
                AppLocalization.string("Port must be between 1 and 65535.")
            case .invalidKind:
                AppLocalization.string("Browser path uses HTTP or SOCKS5.")
            case .sourceMissing:
                AppLocalization.string("Choose a source that still exists.")
            }
        }
    }

    static func browserPath(from document: ConfigurationDocument) -> BrowserPath {
        let entrance = browserEntrance(in: document)
        return BrowserPath(
            enabled: entrance?.enabled ?? false,
            kind: (entrance?.kind == .socks5) ? .socks5 : .http,
            bindAddress: entrance?.bindAddress.isEmpty == false
                ? entrance!.bindAddress
                : "127.0.0.1",
            port: entrance?.port ?? 7890,
            sourceID: sourceID(for: entrance?.defaultAction, in: document)
        )
    }

    static func appPath(from document: ConfigurationDocument) -> AppPath {
        let entrance = document.entrances.first { $0.kind == .appRouting }
        let managed = managedAppRules(in: document)
        let source = managed.compactMap { sourceID(for: $0.action, in: document) }.first
            ?? selectedAppSourceID(in: document)
        return AppPath(
            enabled: entrance?.enabled ?? false,
            sourceID: source,
            applicationPatterns: managed.compactMap(applicationPattern(from:))
        )
    }

    static func applyBrowserPath(
        to original: ConfigurationDocument,
        sourceID: SourceID?,
        kind: EntranceKind,
        port: Int,
        enabled: Bool
    ) throws -> ConfigurationDocument {
        guard kind == .http || kind == .socks5 else { throw Error.invalidKind }
        guard (1...65_535).contains(port) else { throw Error.invalidPort }
        var document = original
        guard var workspace = document.currentWorkspace,
              let workspaceIndex = document.workspaces.firstIndex(where: { $0.id == workspace.id })
        else { throw Error.workspaceMissing }
        if let sourceID {
            guard document.sources.contains(where: { $0.id == sourceID }) else {
                throw Error.sourceMissing
            }
        }

        let action: RoutingAction
        if let sourceID {
            let groupID = try ensureSourceGroup(
                in: &document,
                workspaceIndex: workspaceIndex,
                sourceID: sourceID,
                role: .browser
            )
            action = .proxyGroup(groupID)
        } else {
            action = .direct
        }

        let entranceID = upsertPortEntrance(
            in: &document,
            kind: kind,
            port: port,
            enabled: enabled,
            defaultAction: action
        )
        workspace = document.workspaces[workspaceIndex]
        if !workspace.entranceIDs.contains(entranceID) {
            document.workspaces[workspaceIndex].entranceIDs.append(entranceID)
        }
        document.workspaces[workspaceIndex].revision += 1
        return document
    }

    static func applyAppPath(
        to original: ConfigurationDocument,
        sourceID: SourceID?,
        applicationPatterns: [String],
        enabled: Bool
    ) throws -> ConfigurationDocument {
        var document = original
        guard var workspace = document.currentWorkspace,
              let workspaceIndex = document.workspaces.firstIndex(where: { $0.id == workspace.id })
        else { throw Error.workspaceMissing }
        if let sourceID {
            guard document.sources.contains(where: { $0.id == sourceID }) else {
                throw Error.sourceMissing
            }
        }

        let action: RoutingAction
        if let sourceID {
            let groupID = try ensureSourceGroup(
                in: &document,
                workspaceIndex: workspaceIndex,
                sourceID: sourceID,
                role: .apps
            )
            unlinkOtherAppSourceGroups(
                keeping: groupID,
                workspaceIndex: workspaceIndex,
                in: &document
            )
            action = .proxyGroup(groupID)
        } else {
            unlinkOtherAppSourceGroups(
                keeping: nil,
                workspaceIndex: workspaceIndex,
                in: &document
            )
            action = .direct
        }

        // App Routing's entrance defaultAction becomes MATCH for captured
        // traffic. Keep it Direct so unlisted apps stay Direct; only the
        // managed application rules point at the source group.
        let entranceID = upsertAppRoutingEntrance(
            in: &document,
            enabled: enabled,
            defaultAction: .direct
        )
        workspace = document.workspaces[workspaceIndex]
        if !workspace.entranceIDs.contains(entranceID) {
            document.workspaces[workspaceIndex].entranceIDs.append(entranceID)
        }

        let patterns = uniquePatterns(applicationPatterns)
        let managedIDs = Set(managedAppRules(in: document).map(\.id))
        document.rules.removeAll { managedIDs.contains($0.id) }
        document.workspaces[workspaceIndex].ruleIDs.removeAll { managedIDs.contains($0) }

        if case .proxyGroup = action {
            for pattern in patterns {
                let rule = RoutingRule(
                    id: ruleID(for: pattern),
                    enabled: true,
                    priority: 50,
                    matchers: [.application(pattern)],
                    action: action
                )
                document.rules.append(rule)
                document.workspaces[workspaceIndex].ruleIDs.append(rule.id)
            }
        }
        document.workspaces[workspaceIndex].revision += 1
        return document
    }

    static func isBrowserApplication(_ pattern: String) -> Bool {
        let normalized = pattern.lowercased()
        return browserHints.contains { normalized.contains($0) }
    }

    static func ensureSourceGroup(
        in document: inout ConfigurationDocument,
        workspaceIndex: Int,
        sourceID: SourceID,
        role: Role
    ) throws -> ProxyGroupID {
        if let existing = reusableSourceGroupID(in: document, sourceID: sourceID, role: role) {
            linkGroup(existing, workspaceIndex: workspaceIndex, in: &document)
            return existing
        }
        guard let source = document.sources.first(where: { $0.id == sourceID }) else {
            throw Error.sourceMissing
        }
        let id = groupID(for: sourceID, role: role)
        let group = ProxyGroup(
            id: id,
            name: groupName(source: source, role: role),
            type: .select,
            memberSelectors: [
                NodeSelector(
                    id: selectorID(for: sourceID, role: role),
                    name: source.displayName,
                    include: [.source(sourceID)]
                )
            ]
        )
        if let index = document.proxyGroups.firstIndex(where: { $0.id == id }) {
            document.proxyGroups[index] = group
        } else {
            document.proxyGroups.append(group)
        }
        linkGroup(id, workspaceIndex: workspaceIndex, in: &document)
        return id
    }

    static func groupID(for sourceID: SourceID, role: Role) -> ProxyGroupID {
        ProxyGroupID.stable(for: "mclash-split-path-\(role.rawValue)-source-v1|\(sourceID.rawValue.uuidString)")
    }

    static func ruleID(for applicationPattern: String) -> RoutingRuleID {
        RoutingRuleID.stable(for: "mclash-split-path-app-rule-v1|\(normalizePattern(applicationPattern))")
    }

    static func isManagedAppRule(_ rule: RoutingRule) -> Bool {
        guard let pattern = applicationPattern(from: rule) else { return false }
        return rule.id == ruleID(for: pattern) && rule.matchers.count == 1
    }

    private static let browserHints = [
        "com.google.chrome",
        "com.apple.safari",
        "org.mozilla.firefox",
        "com.microsoft.edgemac",
        "com.brave.browser",
        "company.thebrowser.browser",
        "com.operasoftware.opera",
        "org.chromium.chromium",
        "com.vivaldi.vivaldi",
        "com.kagi.orion",
        "com.apple.mobilesafari",
    ]

    private static func browserEntrance(in document: ConfigurationDocument) -> Entrance? {
        document.entrances.first { $0.kind == .http || $0.kind == .socks5 }
    }

    private static func upsertPortEntrance(
        in document: inout ConfigurationDocument,
        kind: EntranceKind,
        port: Int,
        enabled: Bool,
        defaultAction: RoutingAction
    ) -> EntranceID {
        if let existing = browserEntrance(in: document),
           let index = document.entrances.firstIndex(where: { $0.id == existing.id }) {
            document.entrances[index].kind = kind
            document.entrances[index].port = port
            document.entrances[index].enabled = enabled
            document.entrances[index].bindAddress = existing.bindAddress.isEmpty
                ? "127.0.0.1"
                : existing.bindAddress
            document.entrances[index].defaultAction = defaultAction
            return existing.id
        }
        let entrance = Entrance(
            kind: kind,
            enabled: enabled,
            bindAddress: "127.0.0.1",
            port: port,
            defaultAction: defaultAction
        )
        document.entrances.append(entrance)
        return entrance.id
    }

    private static func upsertAppRoutingEntrance(
        in document: inout ConfigurationDocument,
        enabled: Bool,
        defaultAction: RoutingAction
    ) -> EntranceID {
        if let index = document.entrances.firstIndex(where: { $0.kind == .appRouting }) {
            document.entrances[index].enabled = enabled
            document.entrances[index].defaultAction = defaultAction
            return document.entrances[index].id
        }
        let entrance = Entrance(
            kind: .appRouting,
            enabled: enabled,
            defaultAction: defaultAction
        )
        document.entrances.append(entrance)
        return entrance.id
    }

    private static func reusableSourceGroupID(
        in document: ConfigurationDocument,
        sourceID: SourceID,
        role: Role
    ) -> ProxyGroupID? {
        let stable = groupID(for: sourceID, role: role)
        if document.proxyGroups.contains(where: { $0.id == stable }) {
            return stable
        }
        return document.proxyGroups.first { group in
            group.enabled && isSourceOnlyGroup(group, sourceID: sourceID)
        }?.id
    }

    private static func isSourceOnlyGroup(_ group: ProxyGroup, sourceID: SourceID) -> Bool {
        group.members.isEmpty
            && group.memberSelectors.count == 1
            && group.memberSelectors[0].exclude.isEmpty
            && group.memberSelectors[0].include == [.source(sourceID)]
    }

    private static func linkGroup(
        _ groupID: ProxyGroupID,
        workspaceIndex: Int,
        in document: inout ConfigurationDocument
    ) {
        if !document.workspaces[workspaceIndex].proxyGroupIDs.contains(groupID) {
            document.workspaces[workspaceIndex].proxyGroupIDs.append(groupID)
        }
    }

    private static func selectedAppSourceID(in document: ConfigurationDocument) -> SourceID? {
        guard let linked = document.currentWorkspace?.proxyGroupIDs else { return nil }
        let linkedSet = Set(linked)
        return document.sources.first { source in
            linkedSet.contains(groupID(for: source.id, role: .apps))
        }?.id
    }

    private static func unlinkOtherAppSourceGroups(
        keeping keepID: ProxyGroupID?,
        workspaceIndex: Int,
        in document: inout ConfigurationDocument
    ) {
        let splitPathIDs = Set(document.sources.map { groupID(for: $0.id, role: .apps) })
        document.workspaces[workspaceIndex].proxyGroupIDs.removeAll { id in
            splitPathIDs.contains(id) && id != keepID
        }
    }

    private static func sourceID(
        for action: RoutingAction?,
        in document: ConfigurationDocument
    ) -> SourceID? {
        guard case let .proxyGroup(id) = action,
              let group = document.proxyGroups.first(where: { $0.id == id })
        else { return nil }
        let sources = group.memberSelectors.flatMap(\.include).compactMap { condition -> SourceID? in
            if case let .source(sourceID) = condition { return sourceID }
            return nil
        }
        return sources.count == 1 ? sources[0] : nil
    }

    private static func managedAppRules(in document: ConfigurationDocument) -> [RoutingRule] {
        document.rules.filter(isManagedAppRule).sorted {
            $0.id.rawValue.uuidString < $1.id.rawValue.uuidString
        }
    }

    private static func applicationPattern(from rule: RoutingRule) -> String? {
        guard case let .application(pattern) = rule.matchers.first else { return nil }
        return pattern
    }

    private static func uniquePatterns(_ patterns: [String]) -> [String] {
        var seen = Set<String>()
        return patterns.compactMap { pattern in
            let normalized = normalizePattern(pattern)
            guard !normalized.isEmpty, seen.insert(normalized).inserted else { return nil }
            return normalized
        }
    }

    private static func normalizePattern(_ pattern: String) -> String {
        pattern.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func groupName(source: Source, role: Role) -> String {
        let prefix = role == .browser ? "Browser · " : "Apps · "
        return prefix + source.displayName
    }

    private static func selectorID(for sourceID: SourceID, role: Role) -> UUID {
        ProxyGroupID.stable(
            for: "mclash-split-path-\(role.rawValue)-selector-v1|\(sourceID.rawValue.uuidString)"
        ).rawValue
    }
}
