import Foundation

/// A strategy-owned group hierarchy inspired by the common Clash workflow:
/// rules target one stable selector, while that selector switches between
/// regional, automatic, manual, failover, residential, and direct policies.
/// Imported profile groups are deliberately not consulted.
enum ConfigurationProxyGroupPreset {
    static let mainGroupName = "🚀 节点选择"
    static let hongKongGroupName = "🇭🇰 香港优先"
    static let unitedStatesGroupName = "🇺🇸 美国优先"
    static let japanGroupName = "🇯🇵 日本优先"
    static let failoverGroupName = "🔄 故障转移"
    static let residentialGroupName = "🏠 家宽节点"
    static let manualGroupName = "☑️ 手动切换"
    static let automaticGroupName = "♻️ 自动选择"
    static let highPriorityGroupName = "🚀 高优先级节点"
    static let mediumPriorityGroupName = "🚀 中优先级节点"
    static let directGroupName = "🎯 全球直连"

    static let groupNames: [String] = [
        mainGroupName,
        hongKongGroupName,
        unitedStatesGroupName,
        japanGroupName,
        failoverGroupName,
        residentialGroupName,
        manualGroupName,
        automaticGroupName,
        highPriorityGroupName,
        mediumPriorityGroupName,
        directGroupName,
    ]

    struct Result: Sendable {
        var document: ConfigurationDocument
        let mainGroupID: ProxyGroupID
        let createdGroupCount: Int
        let redirectedRuleCount: Int
    }

    static func apply(
        to original: ConfigurationDocument,
        workspaceID: WorkspaceID? = nil
    ) throws -> Result {
        var document = original
        guard let requestedWorkspace = workspaceID.flatMap({ requested in
            document.workspaces.first(where: { $0.id == requested })
        }) ?? document.currentWorkspace,
        let workspaceIndex = document.workspaces.firstIndex(where: {
            $0.id == requestedWorkspace.id
        }) else {
            throw ConfigurationProxyGroupPresetError.workspaceMissing
        }

        var createdGroupCount = 0
        let existingMain = document.proxyGroups.first(where: {
            $0.name == mainGroupName
        }) ?? document.proxyGroups.first(where: {
            $0.name == "MClash Select"
        })

        func stableID(_ name: String) -> ProxyGroupID {
            ProxyGroupID.stable(for: "mclash-common-routing-groups-v1|" + name)
        }

        func existingID(named name: String) -> ProxyGroupID? {
            document.proxyGroups.first(where: { $0.name == name })?.id
        }

        var directGroupIDForFallback: ProxyGroupID?

        func upsert(
            name: String,
            type: ProxyGroupType,
            members: [ProxyGroupMember] = [],
            preferredID: ProxyGroupID? = nil
        ) -> ProxyGroupID {
            let id = preferredID ?? existingID(named: name) ?? stableID(name)
            // Keep persisted member order (it is meaningful for fallback
            // groups), while preventing duplicate node/group references when
            // a preset is applied over an older document.
            var seenMembers = Set<ProxyGroupMember>()
            let uniqueMembers = members.filter { seenMembers.insert($0).inserted }
            let safeMembers: [ProxyGroupMember]
            if uniqueMembers.isEmpty, type != .direct, type != .reject {
                // A fixed allow-list can legitimately have no match after a
                // provider removes a node. Keep the group valid and fail
                // closed to DIRECT until the next refresh restores a pin.
                safeMembers = [.group(directGroupIDForFallback ?? stableID(directGroupName))]
            } else {
                safeMembers = uniqueMembers
            }
            let replacement = ProxyGroup(
                id: id,
                name: name,
                type: type,
                members: safeMembers,
                enabled: true
            )
            if let index = document.proxyGroups.firstIndex(where: { $0.id == id }) {
                document.proxyGroups[index] = replacement
            } else {
                document.proxyGroups.append(replacement)
                createdGroupCount += 1
            }
            return id
        }

        // Imported profiles are node sources only.  A preset must never let a
        // node from another source leak into its groups.  Keep this lookup
        // tolerant of the common punctuation/spacing variants users use for
        // the source name, while retaining the actual stable SourceID.
        let cunoeSourceIDs = document.sources
            .filter { source in
                let key = source.displayName.unicodeScalars
                    .filter { CharacterSet.alphanumerics.contains($0) }
                    .map(String.init)
                    .joined()
                    .lowercased()
                return key.contains("cunoeproxy")
            }
            .map(\.id)

        // The source profile is intentionally treated as a node catalogue.
        // Do not retain selectors here: selectors would silently pull AWS or
        // provider notice entries into a routing group after a refresh.  The
        // CUNOE plan is a deliberate, fixed allow-list copied from the
        // provider's original groups. Stable NodeIDs keep these pins attached
        // when credentials or display metadata are refreshed.
        let cunoeNodes = document.nodes.filter { node in
            node.enabled && node.sourceLinks.contains { cunoeSourceIDs.contains($0) }
        }
        let originalPlanNames: Set<String> = [
            "🇺🇸 美国|us|9929|ws|private",
            "🇭🇰 香港|ws|private",
            "🇺🇸 美国|us|9929|ws|private|10001VIRCS",
            "🇺🇸 美国|us|9929|ws|private|10002VIRCS",
            "🇺🇸 美国|us|9929|ws|private|10003VIRCS",
            "🇭🇰 香港|juhost|ws",
            "🇺🇸 美国|us|9929|ws|warp",
            "🇯🇵 日本", "🇯🇵 日本 2", "🇯🇵 日本 3", "🇯🇵 日本 4",
        ]
        let pinnedNodes = cunoeNodes.filter { originalPlanNames.contains($0.displayName) }

        func fixedMembers(named names: [String]) -> [ProxyGroupMember] {
            // Preserve the order from the original CUNOE profile.  This is
            // meaningful for fallback groups (first healthy node wins) and
            // makes the priority visible instead of depending on catalog
            // refresh order.
            names.compactMap { name in
                pinnedNodes.first { $0.displayName == name }.map { .node($0.id) }
            }
        }
        let hongKongMembers = fixedMembers(named: [
            "🇭🇰 香港|juhost|ws", "🇭🇰 香港|ws|private", "🇯🇵 日本",
            "🇺🇸 美国|us|9929|ws|private",
        ])
        let unitedStatesMembers = fixedMembers(named: [
            "🇺🇸 美国|us|9929|ws|private", "🇭🇰 香港|juhost|ws",
            "🇭🇰 香港|ws|private", "🇯🇵 日本",
        ])
        let japanMembers = fixedMembers(named: [
            "🇯🇵 日本", "🇭🇰 香港|juhost|ws", "🇭🇰 香港|ws|private",
            "🇺🇸 美国|us|9929|ws|private",
        ])
        let residentialMembers = fixedMembers(named: [
            "🇺🇸 美国|us|9929|ws|private|10001VIRCS",
            "🇺🇸 美国|us|9929|ws|private|10002VIRCS",
            "🇺🇸 美国|us|9929|ws|private|10003VIRCS",
            "🇯🇵 日本 2", "🇯🇵 日本 3", "🇯🇵 日本 4",
        ])
        let manualMembers = pinnedNodes.map { ProxyGroupMember.node($0.id) }
        let automaticMembers = manualMembers
        let highPriorityMembers = fixedMembers(named: [
            "🇺🇸 美国|us|9929|ws|private", "🇭🇰 香港|ws|private",
        ])
        let mediumPriorityMembers = fixedMembers(named: [
            "🇭🇰 香港|juhost|ws", "🇺🇸 美国|us|9929|ws|warp",
        ])

        // Keep a real DIRECT group available as a safe terminal member for
        // fixed groups whose named CUNOE nodes are temporarily absent. This
        // avoids invalid empty groups during a partial subscription refresh.
        let directID = upsert(name: directGroupName, type: .direct)
        directGroupIDForFallback = directID

        // Region fallback order is intentional. If the preferred region is
        // unavailable, mihomo walks the remaining region pools instead of
        // falling straight through to an unrelated raw node.
        let hongKongID = upsert(
            name: hongKongGroupName,
            type: .fallback,
            members: hongKongMembers
        )
        let unitedStatesID = upsert(
            name: unitedStatesGroupName,
            type: .fallback,
            members: unitedStatesMembers
        )
        let japanID = upsert(
            name: japanGroupName,
            type: .fallback,
            members: japanMembers
        )
        let residentialID = upsert(
            name: residentialGroupName,
            type: .select,
            members: residentialMembers
        )
        let manualID = upsert(
            name: manualGroupName,
            type: .select,
            members: manualMembers
        )
        let automaticID = upsert(
            name: automaticGroupName,
            type: .urlTest,
            members: automaticMembers
        )
        let highPriorityID = upsert(
            name: highPriorityGroupName,
            type: .fallback,
            members: highPriorityMembers
        )
        let mediumPriorityID = upsert(
            name: mediumPriorityGroupName,
            type: .fallback,
            members: mediumPriorityMembers
        )
        let failoverID = upsert(
            name: failoverGroupName,
            type: .fallback,
            members: [
                .group(highPriorityID),
                .group(mediumPriorityID),
                .group(automaticID),
                .group(directID),
            ]
        )
        let mainID = upsert(
            name: mainGroupName,
            type: .select,
            members: [
                .group(hongKongID),
                .group(unitedStatesID),
                .group(japanID),
                .group(failoverID),
                .group(residentialID),
                .group(highPriorityID),
                .group(mediumPriorityID),
                .group(manualID),
                .group(automaticID),
                .group(directID),
            ],
            preferredID: existingMain?.id
        )

        let presetIDs = [
            mainID,
            hongKongID,
            unitedStatesID,
            japanID,
            failoverID,
            residentialID,
            manualID,
            automaticID,
            highPriorityID,
            mediumPriorityID,
            directID,
        ]
        let presetIDSet = Set(presetIDs)
        // The built-in MClash Select identity can be shared by several
        // configurations. If it becomes the preset's nested main group, every
        // configuration that already contains it must also contain its child
        // groups or that otherwise untouched configuration would become
        // invalid.
        for index in document.workspaces.indices
        where index == workspaceIndex
            || document.workspaces[index].proxyGroupIDs.contains(mainID) {
            let updated = presetIDs + document.workspaces[index].proxyGroupIDs.filter {
                !presetIDSet.contains($0)
            }
            if document.workspaces[index].proxyGroupIDs != updated {
                document.workspaces[index].proxyGroupIDs = updated
                document.workspaces[index].revision += 1
            }
            if document.workspaces[index].globalProxyGroupID == nil {
                document.workspaces[index].globalProxyGroupID = mainID
                document.workspaces[index].revision += 1
            }
        }

        var redirectedRuleCount = 0
        for position in document.workspaces[workspaceIndex].ruleIDs.indices {
            let ruleID = document.workspaces[workspaceIndex].ruleIDs[position]
            guard let ruleIndex = document.rules.firstIndex(where: { $0.id == ruleID }),
                  case let .proxyGroup(currentTarget) = document.rules[ruleIndex].action,
                  currentTarget != mainID else { continue }

            let sharedWithAnotherWorkspace = document.workspaces.enumerated().contains {
                $0.offset != workspaceIndex && $0.element.ruleIDs.contains(ruleID)
            }
            if sharedWithAnotherWorkspace {
                let originalRule = document.rules[ruleIndex]
                let cloneID = RoutingRuleID.stable(
                    for: "mclash-common-routing-rule-v1|\(requestedWorkspace.id.rawValue)|\(ruleID.rawValue)"
                )
                let clone = RoutingRule(
                    id: cloneID,
                    enabled: originalRule.enabled,
                    priority: originalRule.priority,
                    matchers: originalRule.matchers,
                    action: .proxyGroup(mainID),
                    unavailableFallback: originalRule.unavailableFallback,
                    workspaceScope: requestedWorkspace.id
                )
                if let cloneIndex = document.rules.firstIndex(where: { $0.id == cloneID }) {
                    document.rules[cloneIndex] = clone
                } else {
                    document.rules.append(clone)
                }
                document.workspaces[workspaceIndex].ruleIDs[position] = cloneID
            } else {
                document.rules[ruleIndex].action = .proxyGroup(mainID)
            }
            redirectedRuleCount += 1
        }

        let entranceIDs = Set(document.workspaces[workspaceIndex].entranceIDs)
        for entranceIndex in document.entrances.indices
        where entranceIDs.contains(document.entrances[entranceIndex].id) {
            if case let .proxyGroup(currentTarget) = document.entrances[entranceIndex].defaultAction,
               currentTarget != mainID {
                document.entrances[entranceIndex].defaultAction = .proxyGroup(mainID)
            }
        }

        return Result(
            document: document,
            mainGroupID: mainID,
            createdGroupCount: createdGroupCount,
            redirectedRuleCount: redirectedRuleCount
        )
    }
}

enum ConfigurationProxyGroupPresetError: LocalizedError {
    case workspaceMissing

    var errorDescription: String? {
        switch self {
        case .workspaceMissing:
            AppLocalization.string(
                "Create or select a configuration before adding common strategy groups."
            )
        }
    }
}

private extension UUID {
    static func stable(for value: String) -> UUID {
        ProxyGroupID.stable(for: value).rawValue
    }
}
