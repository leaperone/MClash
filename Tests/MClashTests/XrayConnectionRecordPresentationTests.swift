import Foundation
import Testing
@testable import MClashApp

@Suite("Xray connection record presentation")
struct XrayConnectionRecordPresentationTests {
    @Test("Resolves node, group, and MClash entrance tags while retaining raw tags")
    func resolvesRuntimeTags() throws {
        let nodeID = try #require(UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"))
        let groupID = try #require(UUID(uuidString: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"))
        let record = XrayAccessRecord(
            timestamp: Date(timeIntervalSince1970: 1),
            source: "127.0.0.1:50000",
            destination: "example.com:443",
            transport: "tcp",
            inbound: "mclash-workspace",
            outbound: XrayRuntimePlan.nodeTag(NodeID(rawValue: nodeID))
        )
        let nodeTag = XrayRuntimePlan.nodeTag(NodeID(rawValue: nodeID))
        let groupTag = XrayRuntimePlan.groupTag(ProxyGroupID(rawValue: groupID))
        let nodePresentation = XrayConnectionRecordPresentation(
            record: record,
            nodeNames: [nodeTag: "Tokyo 01"],
            groupNames: [groupTag: "Auto select"],
            localProxyTitle: "Local proxy",
            applicationRoutingTitle: "Application routing"
        )

        #expect(nodePresentation.pathTitle == "Local proxy → Tokyo 01")
        #expect(nodePresentation.pathHelp.contains("mclash-workspace"))
        #expect(nodePresentation.pathHelp.contains(nodeTag))
        #expect(nodePresentation.pathHelp.contains("Local proxy → Tokyo 01"))
        #expect(!nodePresentation.pathHelp.contains("(resolved)"))
        #expect(!nodePresentation.pathHelp.contains("(raw)"))
        #expect(nodePresentation.searchableText.contains("Tokyo 01"))

        let groupPresentation = XrayConnectionRecordPresentation(
            record: XrayAccessRecord(
                timestamp: record.timestamp,
                source: record.source,
                destination: record.destination,
                transport: record.transport,
                inbound: record.inbound,
                outbound: groupTag
            ),
            nodeNames: [:],
            groupNames: [groupTag: "Auto select"],
            localProxyTitle: "Local proxy",
            applicationRoutingTitle: "Application routing"
        )
        #expect(groupPresentation.pathTitle == "Local proxy → Auto select")
        #expect(groupPresentation.pathHelp.contains(groupTag))
    }

    @Test("Resolves a relay tag only through its matching group identifier")
    func resolvesRelayGroup() {
        let groupID = UUID(uuidString: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb")!
        let groupTag = XrayRuntimePlan.groupTag(ProxyGroupID(rawValue: groupID))
        let relayTag = "chain-\(groupID.uuidString.lowercased())-fingerprint-0"
        let record = XrayAccessRecord(
            timestamp: Date(timeIntervalSince1970: 1),
            source: nil,
            destination: "example.com:443",
            transport: "tcp",
            inbound: "mclash-workspace",
            outbound: relayTag
        )
        let presentation = XrayConnectionRecordPresentation(
            record: record,
            nodeNames: [:],
            groupNames: [groupTag: "Relay group"],
            localProxyTitle: "Local proxy",
            applicationRoutingTitle: "Application routing"
        )

        #expect(presentation.pathTitle == "Local proxy → Relay group")
        #expect(presentation.pathHelp.contains(relayTag))
    }

    @Test("Maps application capture entrances to one readable label")
    func resolvesApplicationRoutingTag() {
        let record = XrayAccessRecord(
            timestamp: Date(timeIntervalSince1970: 1),
            source: nil,
            destination: "example.com:443",
            transport: "tcp",
            inbound: "mclash-capture-50123",
            outbound: nil
        )
        let presentation = XrayConnectionRecordPresentation(
            record: record,
            nodeNames: [:],
            groupNames: [:],
            localProxyTitle: "Local proxy",
            applicationRoutingTitle: "Application routing"
        )

        #expect(presentation.pathTitle == "Application routing")
        #expect(presentation.pathHelp.contains("mclash-capture-50123"))
    }
}
