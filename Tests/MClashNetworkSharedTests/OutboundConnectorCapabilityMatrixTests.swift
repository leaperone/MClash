import Foundation
import Testing
@testable import MClashNetworkShared

@Suite("Outbound connector capability matrix")
struct OutboundConnectorCapabilityMatrixTests {
    @Test("Reports every catalog entry in stable route order")
    func reportsEveryEntry() throws {
        let catalog = try OutboundNodeTargetCatalog(entries: [
            .init(route: .group("zeta"), target: OutboundNodeTarget(protocolName: "vmess", host: "z.example", port: 443)),
            .init(route: .global, target: OutboundNodeTarget(protocolName: "socks5", host: "s.example", port: 1080)),
            .init(route: .group("alpha"), target: OutboundNodeTarget(protocolName: "hysteria2", host: "h.example", port: 443))
        ])

        let entries = OutboundConnectorCapabilityMatrix.entries(for: catalog)
        #expect(entries.count == 3)
        #expect(entries.map(\.route) == [.global, .group("alpha"), .group("zeta")])
        #expect(entries[0].support == .native)
        #expect(entries[0].transport == "tcp")
        #expect(entries[1].support == .legacyFallback)
        #expect(entries[1].transport == "quic")
        #expect(entries[2].support == .unsupported)
        #expect(entries[2].reason?.contains("vmess") == true)
    }

    @Test("Distinguishes native VLESS TCP/WebSocket from Reality fallback")
    func classifiesVLESSTransports() throws {
        let targets = [
            try OutboundNodeTarget(protocolName: "vless", host: "tcp.example", port: 443),
            try OutboundNodeTarget(protocolName: "vless", host: "ws.example", port: 443, parameters: ["network": "ws", "uuid": "00000000-0000-0000-0000-000000000001", "ws-path": "/vless"]),
            try OutboundNodeTarget(protocolName: "vless", host: "reality.example", port: 443, parameters: ["security": "reality", "public-key": "key"])
        ]
        let catalog = try OutboundNodeTargetCatalog(entries: targets.enumerated().map { index, target in
            .init(route: .group("v\(index)"), target: target)
        })
        let entries = OutboundConnectorCapabilityMatrix.entries(for: catalog)
        #expect(entries.map(\.support) == [.native, .native, .legacyFallback])
        #expect(entries.map(\.transport) == ["tcp", "ws", "tcp"])
    }

    @Test("Matrix entries round-trip without backend-specific fields")
    func roundTrips() throws {
        let target = try OutboundNodeTarget(protocolName: "trojan", host: "example.com", port: 443)
        let catalog = try OutboundNodeTargetCatalog(entries: [.init(route: .global, target: target)])
        let entry = try #require(OutboundConnectorCapabilityMatrix.entries(for: catalog).first)
        let data = try JSONEncoder().encode(entry)
        let decoded = try JSONDecoder().decode(OutboundConnectorCapabilityMatrixEntry.self, from: data)
        #expect(decoded == entry)
    }
}
