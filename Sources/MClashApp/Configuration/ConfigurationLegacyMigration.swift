import Foundation
import MClashNetworkShared

/// The result of converting the pre-unified App Routing snapshot into the
/// strategy-owned configuration model. Rules that cannot be represented
/// without widening their match are retained as disabled rules with an
/// actionable diagnostic instead of being silently discarded.
struct LegacyCaptureRuleMigrationResult: Sendable {
    let rules: [RoutingRule]
    let proxyGroups: [ProxyGroup]
    let workspaceProxyGroupIDs: [ProxyGroupID]
    let diagnostics: [ConfigurationDiagnostic]
    let migratedCount: Int
    let skippedCount: Int
}

enum ConfigurationLegacyMigration {
    static func migrate(
        captureRules: [CaptureRule],
        document: ConfigurationDocument,
        workspace: Workspace,
        sourceNames: [SourceID: String]
    ) -> LegacyCaptureRuleMigrationResult {
        var groups = document.proxyGroups
        var workspaceGroupIDs = workspace.proxyGroupIDs
        var diagnostics: [ConfigurationDiagnostic] = []
        var migrated: [RoutingRule] = []
        var skippedCount = 0
        let defaultGroupID = ensureDefaultGroup(
            groups: &groups,
            workspaceGroupIDs: &workspaceGroupIDs
        )
        var sourceGroupIDs: [SourceID: ProxyGroupID] = [:]

        for captureRule in captureRules.sorted(by: stableCaptureRuleOrder) {
            let conversion = convertMatchers(captureRule)
            diagnostics.append(contentsOf: conversion.diagnostics)

            let actionConversion = convertAction(
                captureRule.action,
                groups: groups,
                workspaceGroupIDs: workspaceGroupIDs,
                defaultGroupID: defaultGroupID,
                sourceGroupIDs: &sourceGroupIDs,
                sourceNames: sourceNames,
                nodes: document.nodes
            )
            groups = actionConversion.groups
            workspaceGroupIDs = actionConversion.workspaceGroupIDs
            diagnostics.append(contentsOf: actionConversion.diagnostics)

            let hasUnsupportedSources = !captureRule.sources.isEmpty
                && conversion.supportedSourceCount == 0
            let shouldDisable = hasUnsupportedSources
                || conversion.matchers.isEmpty && !captureRule.sources.isEmpty
            if shouldDisable { skippedCount += 1 }

            let ruleID = RoutingRuleID.stable(
                for: "legacy-capture-rule:" + captureRule.id
            )
            migrated.append(
                RoutingRule(
                    id: ruleID,
                    enabled: captureRule.enabled && !shouldDisable,
                    priority: captureRule.priority,
                    matchers: conversion.matchers,
                    action: actionConversion.action,
                    unavailableFallback: captureRule.unavailableFallback == .direct
                        ? .direct
                        : .reject
                )
            )
            if shouldDisable {
                diagnostics.append(.init(
                    severity: .warning,
                    code: "legacy_capture_rule_disabled",
                    subject: captureRule.id,
                    message: AppLocalization.format(
                        "The legacy App Routing rule %@ was retained but disabled because its application identity could not be represented safely in the unified Rules editor.",
                        captureRule.id
                    )
                ))
            }
        }

        return LegacyCaptureRuleMigrationResult(
            rules: migrated,
            proxyGroups: groups,
            workspaceProxyGroupIDs: workspaceGroupIDs,
            diagnostics: diagnostics.sorted { $0.id < $1.id },
            migratedCount: migrated.count - skippedCount,
            skippedCount: skippedCount
        )
    }

    private struct MatcherConversion {
        let matchers: [RoutingMatcher]
        let diagnostics: [ConfigurationDiagnostic]
        let supportedSourceCount: Int
    }

    private static func convertMatchers(_ rule: CaptureRule) -> MatcherConversion {
        var matchers: [RoutingMatcher] = []
        var diagnostics: [ConfigurationDiagnostic] = []
        var supportedSourceCount = 0

        for source in rule.sources {
            switch source {
            case let .application(application):
                let identifiers = [
                    application.bundleIdentifier,
                    application.signingIdentifier,
                ]
                .compactMap { value in
                    value?.trimmingCharacters(in: .whitespacesAndNewlines)
                }
                .filter { !$0.isEmpty }
                if identifiers.isEmpty {
                    diagnostics.append(unsupportedSourceDiagnostic(rule.id))
                } else {
                    let validIdentifiers = identifiers.compactMap { identifier -> String? in
                        guard let normalized = try? ApplicationIdentifierPatternMatcher(
                            pattern: identifier
                        ) else {
                            diagnostics.append(unsupportedSourceDiagnostic(rule.id))
                            return nil
                        }
                        return normalized.pattern
                    }
                    if !validIdentifiers.isEmpty {
                        supportedSourceCount += 1
                        matchers.append(contentsOf: validIdentifiers.map(RoutingMatcher.application))
                    }
                }
            case let .applicationIdentifierPattern(pattern):
                supportedSourceCount += 1
                matchers.append(.application(pattern.pattern))
            case let .executable(executable):
                if executable.canonicalPath.hasPrefix("/") {
                    supportedSourceCount += 1
                    matchers.append(.processPath(executable.canonicalPath))
                } else {
                    diagnostics.append(unsupportedSourceDiagnostic(rule.id))
                }
            case let .processInstance(process):
                if let path = process.canonicalExecutablePath, path.hasPrefix("/") {
                    supportedSourceCount += 1
                    matchers.append(.processPath(path))
                } else {
                    diagnostics.append(unsupportedSourceDiagnostic(rule.id))
                }
            case let .userID(userID):
                supportedSourceCount += 1
                matchers.append(.userID(userID))
            }
        }

        for destination in rule.destinations {
            switch destination {
            case let .ip(address):
                matchers.append(
                    .ipCIDR(address.presentation + "/" + String(address.family.bitCount))
                )
            case let .network(network):
                matchers.append(.ipCIDR(network.presentation))
            case let .host(host):
                switch host.kind {
                case .exact:
                    matchers.append(.domainExact(host.value))
                case .suffix:
                    matchers.append(.domainSuffix(host.value))
                }
            case let .hostPattern(pattern):
                matchers.append(.domainWildcard(pattern.pattern))
            }
        }

        for protocolType in rule.protocols.sorted(by: { $0.rawValue < $1.rawValue }) {
            matchers.append(.transport(protocolType.rawValue))
        }
        for range in rule.portRanges.sorted(by: {
            if $0.lowerBound == $1.lowerBound {
                return $0.upperBound < $1.upperBound
            }
            return $0.lowerBound < $1.lowerBound
        }) {
            if range.lowerBound == range.upperBound {
                matchers.append(.port(Int(range.lowerBound)))
            } else {
                matchers.append(
                    .portRange(
                        Int(range.lowerBound)...Int(range.upperBound)
                    )
                )
            }
        }
        return MatcherConversion(
            matchers: matchers,
            diagnostics: diagnostics,
            supportedSourceCount: supportedSourceCount
        )
    }

    private struct ActionConversion {
        let action: RoutingAction
        let groups: [ProxyGroup]
        let workspaceGroupIDs: [ProxyGroupID]
        let diagnostics: [ConfigurationDiagnostic]
    }

    private static func convertAction(
        _ action: CaptureAction,
        groups: [ProxyGroup],
        workspaceGroupIDs: [ProxyGroupID],
        defaultGroupID: ProxyGroupID,
        sourceGroupIDs: inout [SourceID: ProxyGroupID],
        sourceNames: [SourceID: String],
        nodes: [Node]
    ) -> ActionConversion {
        var groups = groups
        var workspaceGroupIDs = workspaceGroupIDs
        var diagnostics: [ConfigurationDiagnostic] = []
        let converted: RoutingAction

        switch action {
        case .direct:
            converted = .direct
        case .reject:
            converted = .reject
        case let .outbound(route):
            switch route {
            case .profileRules, .global:
                converted = .proxyGroup(defaultGroupID)
            case let .group(name):
                if let group = groups.first(where: {
                    $0.enabled && $0.name == name
                }) {
                    converted = .proxyGroup(group.id)
                } else {
                    converted = .proxyGroup(defaultGroupID)
                    diagnostics.append(.init(
                        severity: .warning,
                        code: "legacy_capture_group_fallback",
                        subject: name,
                        message: AppLocalization.format(
                            "A legacy App Routing rule referenced the source group %@, which is not imported; MClash routed it to the default node group.",
                            name
                        )
                    ))
                }
            case let .profile(profileID, _):
                let sourceID = SourceID(rawValue: profileID.uuid)
                let groupID: ProxyGroupID
                if let existing = sourceGroupIDs[sourceID] {
                    groupID = existing
                } else {
                    groupID = ProxyGroupID.stable(
                        for: "legacy-capture-source-group:"
                            + sourceID.rawValue.uuidString.lowercased()
                    )
                    let displayName = sourceNames[sourceID]
                        ?? "Source " + String(sourceID.rawValue.uuidString.prefix(8))
                    let group = ProxyGroup(
                        id: groupID,
                        name: "Nodes · " + displayName,
                        type: .select,
                        memberSelectors: [
                            NodeSelector(
                                name: "Nodes from " + displayName,
                                include: [.source(sourceID)]
                            )
                        ],
                        enabled: true
                    )
                    groups.append(group)
                    sourceGroupIDs[sourceID] = groupID
                    if !nodes.contains(where: { $0.sourceLinks.contains(sourceID) }) {
                        diagnostics.append(.init(
                            severity: .warning,
                            code: "legacy_capture_source_empty",
                            subject: sourceID.rawValue.uuidString.lowercased(),
                            message: AppLocalization.format(
                                "The legacy App Routing target %@ has no imported nodes; its migrated rule will wait for a matching source refresh.",
                                displayName
                            )
                        ))
                    }
                }
                if !workspaceGroupIDs.contains(groupID) {
                    workspaceGroupIDs.append(groupID)
                }
                converted = .proxyGroup(groupID)
            }
        }
        return ActionConversion(
            action: converted,
            groups: groups,
            workspaceGroupIDs: workspaceGroupIDs,
            diagnostics: diagnostics
        )
    }

    private static func ensureDefaultGroup(
        groups: inout [ProxyGroup],
        workspaceGroupIDs: inout [ProxyGroupID]
    ) -> ProxyGroupID {
        if let existing = groups.first(where: {
            workspaceGroupIDs.contains($0.id)
                && $0.enabled
                && $0.type != .direct
                && $0.type != .reject
        }) {
            return existing.id
        }
        if let existing = groups.first(where: {
            $0.name == "MClash Select" && $0.enabled
        }) {
            if !workspaceGroupIDs.contains(existing.id) {
                workspaceGroupIDs.append(existing.id)
            }
            return existing.id
        }
        let group = ProxyGroup(
            id: ProxyGroupID.stable(for: "legacy-capture-default-group"),
            name: "MClash Select",
            type: .select,
            memberSelectors: [NodeSelector(name: "All enabled nodes")],
            enabled: true
        )
        groups.append(group)
        workspaceGroupIDs.append(group.id)
        return group.id
    }

    private static func stableCaptureRuleOrder(
        _ lhs: CaptureRule,
        _ rhs: CaptureRule
    ) -> Bool {
        if lhs.priority == rhs.priority { return lhs.id < rhs.id }
        return lhs.priority < rhs.priority
    }

    private static func unsupportedSourceDiagnostic(
        _ ruleID: String
    ) -> ConfigurationDiagnostic {
        .init(
            severity: .warning,
            code: "legacy_capture_source_unsupported",
            subject: ruleID,
            message: AppLocalization.string(
                "A legacy App Routing application identity could not be represented safely and was retained for review."
            )
        )
    }
}
