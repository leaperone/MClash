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

    @Test("Native listener manager starts only configured loopback sockets and stops them")
    func managerLifecycle() async throws {
        let id = UUID()
        let port = UInt16.random(in: 20_000...60_000)
        let spec = try MClashListenerSpec(
            id: id,
            name: "Ephemeral HTTP",
            kind: .http,
            enabled: true,
            port: Int(port)
        )
        let registry = try MClashListenerRegistry(listeners: [spec])
        let manager = NativeInboundListenerManager(
            routeResolver: { spec, _ in spec.route == .direct ? .direct : .reject },
            connector: Connector()
        )
        try manager.configure(registry)
        #expect(manager.lifecycleStates()[id] == .stopped)
        manager.start()
        // NWListener reports readiness asynchronously; starting is the only
        // state that may be observed immediately after start().
        let initial = manager.lifecycleStates()[id]
        #expect(initial == .starting || initial == .running(port: port))
        try await Task.sleep(for: .milliseconds(100))
        #expect(manager.lifecycleStates()[id] == .running(port: port))
        manager.stop()
        #expect(manager.lifecycleStates()[id] == .stopped)
    }

    @Test("Disabled and system entrances never bind a socket")
    func managerDoesNotBindDisabledEntrances() throws {
        let disabled = try MClashListenerSpec(
            name: "Disabled SOCKS",
            kind: .socks5,
            enabled: false,
            port: 19_288
        )
        let app = try MClashListenerSpec(
            name: "Application Routing",
            kind: .appRouting,
            enabled: true
        )
        let manager = NativeInboundListenerManager(
            routeResolver: { _, _ in .direct },
            connector: Connector()
        )
        try manager.configure(try MClashListenerRegistry(listeners: [disabled, app]))
        manager.start()
        #expect(manager.lifecycleStates()[disabled.id] == .stopped)
        #expect(manager.lifecycleStates()[app.id] == .stopped)
        manager.stop()
    }

    @Test("Outbound listener routes are rejected until an inbound handshake connector exists")
    func outboundRouteRequiresHandshakeConnector() throws {
        let route: OutboundRoute = .group("CUNOE")
        let target = try OutboundNodeTarget(
            protocolName: "socks5",
            host: "proxy.example.com",
            port: 1080
        )
        let catalog = try OutboundNodeTargetCatalog(
            entries: [OutboundNodeTargetEntry(route: route, target: target)]
        )
        let spec = try MClashListenerSpec(
            name: "Native HTTP",
            kind: .http,
            enabled: true,
            port: 20_811,
            route: .outbound(route)
        )
        let manager = NativeInboundListenerManager(
            routeResolver: { _, _ in .direct },
            connector: Connector()
        )
        #expect(throws: NativeInboundListenerConfigurationError.unsupportedOutboundTransport(
            route: route,
            protocolName: "socks5"
        )) {
            try manager.configure(
                try MClashListenerRegistry(listeners: [spec]),
                outboundCatalog: catalog
            )
        }
    }

    @Test("Unsupported native outbound protocols fail closed at configure time")
    func unsupportedOutboundRouteIsRejected() throws {
        let route: OutboundRoute = .group("Legacy")
        let target = try OutboundNodeTarget(
            protocolName: "tuic",
            host: "proxy.example.com",
            port: 443
        )
        let catalog = try OutboundNodeTargetCatalog(
            entries: [OutboundNodeTargetEntry(route: route, target: target)]
        )
        let spec = try MClashListenerSpec(
            name: "Unsupported SOCKS",
            kind: .socks5,
            enabled: true,
            port: 20_812,
            route: .outbound(route)
        )
        let manager = NativeInboundListenerManager(
            routeResolver: { _, _ in .direct },
            connector: Connector()
        )
        #expect(throws: NativeInboundListenerConfigurationError.unsupportedOutboundProtocol(
            route: route,
            protocolName: "tuic"
        )) {
            try manager.configure(
                try MClashListenerRegistry(listeners: [spec]),
                outboundCatalog: catalog
            )
        }
    }
}
