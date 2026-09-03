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

    @Test("SOCKS5 outbound listener routes are accepted with an inbound handshake connector")
    func outboundSOCKS5RouteUsesHandshakeConnector() throws {
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
        try manager.configure(
            try MClashListenerRegistry(listeners: [spec]),
            outboundCatalog: catalog
        )
        #expect(manager.lifecycleStates()[spec.id] == .stopped)
    }

    @Test("Native inbound accepts supported HTTP, VLESS TCP and Trojan targets")
    func supportedProtocolRoutesConfigure() throws {
        let targets: [(String, [String: String])] = [
            ("http", [:]),
            ("vless", ["uuid": UUID().uuidString]),
            ("trojan", ["password": "test-password"])
        ]
        for (index, item) in targets.enumerated() {
            let route = OutboundRoute.group("native-\(item.0)")
            let target = try OutboundNodeTarget(
                protocolName: item.0,
                host: "127.0.0.1",
                port: 443,
                parameters: item.1
            )
            let catalog = try OutboundNodeTargetCatalog(
                entries: [OutboundNodeTargetEntry(route: route, target: target)]
            )
            let spec = try MClashListenerSpec(
                name: "Native \(item.0)",
                kind: .http,
                enabled: true,
                port: 20_900 + index,
                route: .outbound(route)
            )
            let manager = NativeInboundListenerManager(
                routeResolver: { _, _ in .direct },
                connector: Connector()
            )
            try manager.configure(
                try MClashListenerRegistry(listeners: [spec]),
                outboundCatalog: catalog
            )
            #expect(manager.lifecycleStates()[spec.id] == .stopped)
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

    @Test("Invalid reload preserves the last known-good listener generation")
    func invalidReloadIsTransactional() async throws {
        let id = UUID()
        let port = UInt16.random(in: 20_000...60_000)
        let initial = try MClashListenerSpec(
            id: id,
            name: "Stable HTTP",
            kind: .http,
            enabled: true,
            port: Int(port)
        )
        let manager = NativeInboundListenerManager(
            routeResolver: { _, _ in .direct },
            connector: Connector()
        )
        let initialRegistry = try MClashListenerRegistry(listeners: [initial])
        try manager.configure(initialRegistry)
        manager.start()
        try await Task.sleep(for: .milliseconds(100))
        #expect(manager.lifecycleStates()[id] == .running(port: port))

        let route: OutboundRoute = .group("unsupported")
        let target = try OutboundNodeTarget(
            protocolName: "tuic",
            host: "127.0.0.1",
            port: 443
        )
        let invalidCatalog = try OutboundNodeTargetCatalog(
            entries: [OutboundNodeTargetEntry(route: route, target: target)]
        )
        let invalid = try MClashListenerSpec(
            name: "Invalid replacement",
            kind: .socks5,
            enabled: true,
            port: Int(port) + 1,
            route: .outbound(route)
        )
        #expect(throws: NativeInboundListenerConfigurationError.unsupportedOutboundProtocol(
            route: route,
            protocolName: "tuic"
        )) {
            try manager.configure(
                try MClashListenerRegistry(listeners: [invalid]),
                outboundCatalog: invalidCatalog
            )
        }
        #expect(manager.configuredRegistry() == initialRegistry)
        #expect(manager.lifecycleStates()[id] == .running(port: port))
        manager.stop()
    }

    /// A real loopback SOCKS5 server is used here rather than only asserting
    /// encoded bytes. This protects the important ordering guarantee: the
    /// inbound connector must finish the upstream greeting and CONNECT reply
    /// before the listener can acknowledge its client.
    @Test("Native SOCKS5 inbound connector completes greeting and CONNECT")
    func nativeSOCKS5OutboundHandshakeLoopback() async throws {
        let fixture = try LoopbackSOCKS5Fixture()
        let port = try await fixture.start()
        defer { fixture.stop() }

        let route: OutboundRoute = .group("Loopback")
        let target = try OutboundNodeTarget(
            protocolName: "socks5",
            host: "127.0.0.1",
            port: port
        )
        let catalog = try OutboundNodeTargetCatalog(
            entries: [OutboundNodeTargetEntry(route: route, target: target)]
        )
        let connector = NativeInboundCatalogConnector(catalog: catalog)
        let connection = connector.connect(
            to: MClashInboundDestination(host: "example.com", port: 443),
            route: .proxy(route.stableSortKey)
        )

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    connector.establish(
                        connection,
                        to: MClashInboundDestination(host: "example.com", port: 443),
                        route: .proxy(route.stableSortKey)
                    ) { error in
                        if let error { continuation.resume(throwing: error) }
                        else { continuation.resume() }
                    }
                case .failed(let error):
                    continuation.resume(throwing: error)
                default:
                    break
                }
            }
            connection.start(queue: DispatchQueue(label: "one.leaper.mclash.socks5-fixture-client"))
        }

        #expect(fixture.didReceiveGreeting)
        #expect(fixture.didReceiveConnect)
        connection.cancel()
    }

    private final class LoopbackSOCKS5Fixture: @unchecked Sendable {
        private let listener: NWListener
        private let queue = DispatchQueue(label: "one.leaper.mclash.socks5-fixture")
        private var connection: NWConnection?
        private var stage = 0
        private var bytes = Data()
        private var readyContinuation: CheckedContinuation<UInt16, Error>?
        private(set) var didReceiveGreeting = false
        private(set) var didReceiveConnect = false

        init() throws {
            listener = try NWListener(using: .tcp, on: .any)
        }

        func start() async throws -> UInt16 {
            try await withCheckedThrowingContinuation { continuation in
                readyContinuation = continuation
                listener.stateUpdateHandler = { [weak self] state in
                    guard let self else { return }
                    switch state {
                    case .ready:
                        self.readyContinuation?.resume(returning: self.listener.port?.rawValue ?? 0)
                        self.readyContinuation = nil
                    case .failed(let error):
                        self.readyContinuation?.resume(throwing: error)
                        self.readyContinuation = nil
                    default:
                        break
                    }
                }
                listener.newConnectionHandler = { [weak self] connection in
                    guard let self else { connection.cancel(); return }
                    self.connection = connection
                    connection.start(queue: self.queue)
                    self.receive()
                }
                listener.start(queue: queue)
            }
        }

        func stop() {
            connection?.cancel()
            listener.cancel()
        }

        private func receive() {
            connection?.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, complete, error in
                guard let self else { return }
                if error != nil || complete { return }
                if let data { self.bytes.append(data) }
                self.consume()
                self.receive()
            }
        }

        private func consume() {
            if stage == 0, bytes.count >= 3, bytes.prefix(3) == Data([5, 1, 0]) {
                didReceiveGreeting = true
                stage = 1
                bytes.removeAll()
                connection?.send(content: Data([5, 0]), completion: .contentProcessed { _ in })
            } else if stage == 1, bytes.count >= 17 {
                // SOCKS5 CONNECT example.com:443 is exactly 17 bytes.
                didReceiveConnect = true
                stage = 2
                bytes.removeAll()
                connection?.send(
                    content: Data([5, 0, 0, 1, 127, 0, 0, 1, 0x1F, 0x90]),
                    completion: .contentProcessed { _ in }
                )
            }
        }
    }
}
