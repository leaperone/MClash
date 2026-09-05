import Foundation
import Testing
@testable import MClashNetworkShared

@Suite("VLESS WebSocket transport options")
struct VLESSWebSocketTransportTests {
    @Test("Parses Clash ws-opts JSON and normalizes the path")
    func parsesNestedOptions() throws {
        let target = try OutboundNodeTarget(
            protocolName: "vless", host: "edge.example.com", port: 443,
            parameters: [
                "network": "ws",
                "ws-opts": #"{"path":"api/v1","headers":{"Host":"cdn.example.com","User-Agent":"mclash"}}"#,
            ]
        )
        #expect(target.vlessWebSocketOptions == VLESSWebSocketOptions(
            path: "/api/v1",
            headers: ["Host": "cdn.example.com", "User-Agent": "mclash"]
        ))
    }

    @Test("Parses flattened importer aliases and preserves explicit Host")
    func parsesFlattenedAliases() throws {
        let target = try OutboundNodeTarget(
            protocolName: "VLESS", host: "edge.example.com", port: 443,
            parameters: ["network": "ws", "ws_path": "/socket", "ws_host": "cdn.example.com"]
        )
        #expect(target.vlessWebSocketOptions?.path == "/socket")
        #expect(target.vlessWebSocketOptions?.headers["Host"] == "cdn.example.com")
    }

    @Test("Does not invent WebSocket options for TCP targets")
    func excludesTCP() throws {
        let target = try OutboundNodeTarget(
            protocolName: "vless", host: "edge.example.com", port: 443,
            parameters: ["ws-opts": #"{"path":"/socket"}"#]
        )
        #expect(target.vlessWebSocketOptions == nil)
    }

    @Test("Distinguishes valid defaults from malformed explicit options")
    func distinguishesDefaultsFromMalformedOptions() throws {
        let defaults = try OutboundNodeTarget(
            protocolName: "vless", host: "edge.example.com", port: 443,
            parameters: ["network": "ws"]
        )
        #expect(defaults.vlessWebSocketOptions == nil)
        #expect(!defaults.hasInvalidVLESSWebSocketOptions)

        let malformed = try OutboundNodeTarget(
            protocolName: "vless", host: "edge.example.com", port: 443,
            parameters: ["network": "ws", "ws-opts": "not-json"]
        )
        #expect(malformed.vlessWebSocketOptions == nil)
        #expect(malformed.hasInvalidVLESSWebSocketOptions)

        let malformedField = try OutboundNodeTarget(
            protocolName: "vless", host: "edge.example.com", port: 443,
            parameters: ["network": "ws", "ws-opts": #"{"path":42}"#]
        )
        #expect(malformedField.vlessWebSocketOptions == nil)
        #expect(malformedField.hasInvalidVLESSWebSocketOptions)
    }
}
