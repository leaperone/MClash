import Foundation

struct XrayConnectionRecordPresentation: Equatable, Sendable, Identifiable {
    let record: XrayAccessRecord
    let sourceTitle: String
    let pathTitle: String
    let pathHelp: String

    var id: UUID { record.id }

    init(
        record: XrayAccessRecord,
        nodeNames: [String: String],
        groupNames: [String: String],
        localProxyTitle: String,
        applicationRoutingTitle: String,
        unknownSourceTitle: String = "Unknown source",
        missingPathTitle: String = "No entrance or node was reported for this connection event."
    ) {
        self.record = record
        sourceTitle = record.source ?? unknownSourceTitle

        let rawParts = [record.inbound, record.outbound].compactMap { $0 }
        let resolvedParts = rawParts.map { tag in
            Self.resolvedTitle(
                for: tag,
                nodeNames: nodeNames,
                groupNames: groupNames,
                localProxyTitle: localProxyTitle,
                applicationRoutingTitle: applicationRoutingTitle
            )
        }
        pathTitle = resolvedParts.isEmpty ? "—" : resolvedParts.joined(separator: " → ")
        pathHelp = Self.pathHelp(
            rawParts: rawParts,
            resolvedParts: resolvedParts,
            missingPathTitle: missingPathTitle
        )
    }

    var searchableText: [String] {
        [
            sourceTitle,
            record.destination,
            record.transport,
            record.inbound,
            record.outbound,
            pathTitle,
            pathHelp,
        ].compactMap { $0 }
    }

    private static func resolvedTitle(
        for tag: String,
        nodeNames: [String: String],
        groupNames: [String: String],
        localProxyTitle: String,
        applicationRoutingTitle: String
    ) -> String {
        if let nodeName = nodeNames[tag], !nodeName.isEmpty {
            return nodeName
        }
        if let groupName = groupNames[tag], !groupName.isEmpty {
            return groupName
        }
        if tag.hasPrefix("chain-") {
            let suffix = tag.dropFirst("chain-".count)
            let groupIDText = String(suffix.prefix(36))
            if let groupID = UUID(uuidString: groupIDText),
               let groupName = groupNames[XrayRuntimePlan.groupTag(ProxyGroupID(rawValue: groupID))],
               !groupName.isEmpty {
                return groupName
            }
        }
        if tag == "mclash-workspace" {
            return localProxyTitle
        }
        if tag.hasPrefix("mclash-capture-") {
            return applicationRoutingTitle
        }
        return tag
    }

    private static func pathHelp(
        rawParts: [String],
        resolvedParts: [String],
        missingPathTitle: String
    ) -> String {
        guard !rawParts.isEmpty else {
            return missingPathTitle
        }
        let resolved = resolvedParts.joined(separator: " → ")
        let raw = rawParts.joined(separator: " → ")
        guard resolved != raw else { return raw }
        return "\(resolved)\n\(raw)"
    }
}
