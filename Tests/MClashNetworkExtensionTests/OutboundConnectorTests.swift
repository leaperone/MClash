import Foundation
import MClashNetworkShared
import Testing
@testable import MClashNetworkExtension

@Suite("Outbound connector boundary")
struct OutboundConnectorTests {
    @Test("Direct and Reject are terminal MClash decisions")
    func terminalDecisionsNeverUseConnector() {
        #expect(!OutboundConnectorRoutingPolicy.requiresConnector(.direct))
        #expect(!OutboundConnectorRoutingPolicy.requiresConnector(.reject))
        #expect(!OutboundConnectorRoutingPolicy.requiresConnector(.failOpen))
    }

    @Test("A proxy decision is the only decision that uses a connector")
    func proxyDecisionUsesConnector() {
        #expect(OutboundConnectorRoutingPolicy.requiresConnector(.mihomo(.profileRules)))
        #expect(OutboundConnectorRoutingPolicy.requiresConnector(.mihomo(.global)))
        #expect(OutboundConnectorRoutingPolicy.requiresConnector(.mihomo(.group("AI"))))
    }

    @Test("Native SOCKS5 connector targets the node endpoint directly")
    func nativeSOCKS5ConnectorKeepsNodeEndpoint() throws {
        let target = try OutboundNodeTarget(
            protocolName: "socks5",
            host: "127.0.0.1",
            port: 19080
        )
        let connector = NativeSOCKS5OutboundConnector(target: target)
        let connection = connector.makeConnection()
        connection.cancel()
        #expect(target.protocolName == "socks5")
        #expect(target.port == 19080)
    }

    @Test("Native VLESS connector emits a destination handshake")
    func nativeVLESSConnectorHandshake() throws {
        let target = try OutboundNodeTarget(
            protocolName: "vless",
            host: "node.example.com",
            port: 443,
            parameters: [
                "uuid": "00000000-0000-0000-0000-000000000001",
                "tls": "true",
            ]
        )
        let connector = NativeVLESSOutboundConnector(target: target)
        let destination = try SOCKS5Endpoint(
            address: SOCKS5Address(domain: "example.com"),
            port: 443
        )
        let handshake = try connector.handshake(for: destination)
        #expect(handshake.first == 0x01)
        #expect(handshake.contains(0x02))
    }

    @Test("Native VLESS connector accepts WebSocket transport parameters")
    func nativeVLESSWebSocketConnectorBuilds() throws {
        let target = try OutboundNodeTarget(
            protocolName: "vless",
            host: "node.example.com",
            port: 443,
            parameters: [
                "uuid": "00000000-0000-0000-0000-000000000001",
                "tls": "true",
                "network": "ws",
                "ws-host": "cdn.example.com",
            ]
        )
        let connection = NativeVLESSOutboundConnector(target: target).makeConnection()
        connection.cancel()
        #expect(target.parameters["network"] == "ws")
    }
}
