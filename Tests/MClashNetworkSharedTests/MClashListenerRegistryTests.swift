import Foundation
import Testing
@testable import MClashNetworkShared

@Suite("MClash listener registry")
struct MClashListenerRegistryTests {
    @Test("HTTP and SOCKS entries round-trip through a connector-neutral payload")
    func roundTrip() throws {
        let http = try MClashListenerSpec(
            id: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
            name: "HTTP local",
            kind: .http,
            enabled: true,
            port: 18_080,
            route: .outbound(.global)
        )
        let socks = try MClashListenerSpec(
            id: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
            name: "SOCKS local",
            kind: .socks5,
            enabled: true,
            bindAddress: "::1",
            port: 18_081
        )
        let registry = try MClashListenerRegistry(listeners: [http, socks])
        let decoded = try MClashListenerRegistry.decode(try registry.encoded())
        #expect(decoded == registry)
        #expect(decoded.listener(id: http.id)?.endpoint == "127.0.0.1:18080")
        #expect(decoded.listener(id: socks.id)?.endpoint == "[::1]:18081")
    }

    @Test("Native registry rejects non-loopback listeners")
    func rejectsNonLoopback() throws {
        #expect(throws: MClashListenerRegistryError.nonLoopbackBindAddress("0.0.0.0")) {
            try MClashListenerSpec(
                name: "exposed",
                kind: .http,
                bindAddress: "0.0.0.0",
                port: 18_080
            )
        }
    }

    @Test("App Routing and TUN are capability entries without socket ports")
    func capabilityEntries() throws {
        let app = try MClashListenerSpec(name: "Apps", kind: .appRouting, enabled: true)
        let tun = try MClashListenerSpec(name: "TUN", kind: .tun)
        let registry = try MClashListenerRegistry(listeners: [app, tun])
        #expect(registry.enabledListeners.count == 1)
        #expect(app.endpoint == nil)
    }

    @Test("Disabled socket entrances may stage a port used by an enabled entrance")
    func disabledEntrancesDoNotReservePorts() throws {
        let active = try MClashListenerSpec(
            name: "Active",
            kind: .http,
            enabled: true,
            port: 18_080
        )
        let staged = try MClashListenerSpec(
            name: "Staged",
            kind: .socks5,
            enabled: false,
            port: 18_080
        )
        let registry = try MClashListenerRegistry(listeners: [active, staged])
        #expect(registry.enabledListeners.map(\.name) == ["Active"])
    }

    @Test("Two enabled entrances still reject the same endpoint")
    func enabledEntrancesReservePorts() throws {
        let first = try MClashListenerSpec(name: "First", kind: .http, enabled: true, port: 18_080)
        let second = try MClashListenerSpec(name: "Second", kind: .socks5, enabled: true, port: 18_080)
        #expect(throws: MClashListenerRegistryError.duplicateEndpoint("127.0.0.1:18080")) {
            try MClashListenerRegistry(listeners: [first, second])
        }
    }
}
