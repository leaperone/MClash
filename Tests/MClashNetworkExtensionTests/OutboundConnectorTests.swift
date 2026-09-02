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
}
