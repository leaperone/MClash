import Foundation
@preconcurrency import Network
import Testing
@testable import MClashNetworkExtension

@Suite("MClash-owned inbound listener")
struct MClashInboundListenerTests {
    private struct Connector: MClashInboundOutboundConnector {
        func connect(to destination: MClashInboundDestination, route: MClashInboundRoute) -> NWConnection {
            NWConnection(host: NWEndpoint.Host(destination.host), port: NWEndpoint.Port(rawValue: destination.port)!, using: .tcp)
        }
    }

    @Test("Can create, start and stop an ephemeral HTTP entrance")
    func lifecycle() throws {
        let listener = try MClashInboundListener(kind: .httpConnect, route: { _ in .direct }, connector: Connector())
        listener.start()
        listener.stop()
    }

    @Test("Routing callback is independent from the outbound connector")
    func routeValues() {
        let destination = MClashInboundDestination(host: "example.com", port: 443)
        #expect(MClashInboundRoute.direct != .proxy("AI"))
        #expect(destination == MClashInboundDestination(host: "example.com", port: 443))
    }
}
