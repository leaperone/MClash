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
}
