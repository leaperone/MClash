import Testing
@testable import MClashNetworkExtension
import MClashNetworkShared

@Suite("Hysteria2 QUIC session adapter")
struct Hysteria2QUICSessionTests {
    @Test("Constructs from connector-neutral node target without Mihomo state")
    func constructs() throws {
        let target = try OutboundNodeTarget(
            protocolName: "hysteria2",
            host: "node.example.com",
            port: 443,
            parameters: ["password": "secret"]
        )
        let connector = NativeHysteria2OutboundConnector(target: target)
        let session = Hysteria2QUICSession(connector: connector)
        session.cancel()
        #expect(target.protocolName == "hysteria2")
    }
}
