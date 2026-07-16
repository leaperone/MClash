import Foundation
import Testing
@testable import MClashApp

@Suite("System proxy state manager")
struct SystemProxyManagerTests {
    @Test("Snapshot includes only enabled services and exact proxy dictionaries")
    func snapshotEnabledServices() async throws {
        let wiFi = SystemProxyNetworkService(id: "wifi", name: "Wi-Fi")
        let ethernet = SystemProxyNetworkService(id: "ethernet", name: "Ethernet")
        let disabled = SystemProxyNetworkService(id: "disabled", name: "Disabled")
        let wiFiState = try SystemProxyServiceState(
            service: wiFi,
            protocolExists: true,
            configuration: originalConfiguration
        )
        let ethernetState = try SystemProxyServiceState(
            service: ethernet,
            protocolExists: false,
            configuration: nil
        )
        let disabledState = try SystemProxyServiceState(
            service: disabled,
            protocolExists: true,
            configuration: [SystemProxyKeys.httpEnable: .integer(1)]
        )
        let backend = FakeSystemProxyBackend(
            enabledServices: [wiFi, ethernet],
            states: [wiFiState, ethernetState, disabledState]
        )
        let manager = SystemProxyManager(backend: backend)
        let capturedAt = Date(timeIntervalSince1970: 1_700_000_000)

        let snapshot = try await manager.captureSnapshot(at: capturedAt)

        #expect(snapshot.capturedAt == capturedAt)
        #expect(snapshot.services == [wiFiState, ethernetState])
    }

    @Test("Apply writes local HTTP, HTTPS, and SOCKS endpoints without losing unrelated keys")
    func applyLocalEndpoints() async throws {
        let service = SystemProxyNetworkService(id: "wifi", name: "Wi-Fi")
        let initialState = try SystemProxyServiceState(
            service: service,
            protocolExists: true,
            configuration: originalConfiguration
        )
        let backend = FakeSystemProxyBackend(
            enabledServices: [service],
            states: [initialState]
        )
        let manager = SystemProxyManager(backend: backend)
        let endpoints = LocalSystemProxyEndpoints(
            http: try SystemProxyEndpoint(port: 7_890),
            https: try SystemProxyEndpoint(port: 7_891),
            socks: try SystemProxyEndpoint(port: 7_892)
        )

        try await manager.apply(endpoints: endpoints)

        let state = try #require(backend.currentStates.first)
        let configuration = try #require(state.configuration)
        #expect(configuration[SystemProxyKeys.httpEnable] == .integer(1))
        #expect(configuration[SystemProxyKeys.httpHost] == .string("127.0.0.1"))
        #expect(configuration[SystemProxyKeys.httpPort] == .integer(7_890))
        #expect(configuration[SystemProxyKeys.httpsPort] == .integer(7_891))
        #expect(configuration[SystemProxyKeys.socksPort] == .integer(7_892))
        #expect(configuration[SystemProxyKeys.pacEnable] == .integer(0))
        #expect(configuration[SystemProxyKeys.autoDiscoveryEnable] == .integer(0))
        #expect(configuration["ExceptionsList"] == originalConfiguration["ExceptionsList"])
        #expect(configuration["CustomFutureKey"] == .bool(true))
    }

    @Test("Restore reapplies the precise previous state, including absent protocols")
    func exactRestore() async throws {
        let wiFi = SystemProxyNetworkService(id: "wifi", name: "Wi-Fi")
        let ethernet = SystemProxyNetworkService(id: "ethernet", name: "Ethernet")
        let originalStates = [
            try SystemProxyServiceState(
                service: wiFi,
                protocolExists: true,
                configuration: originalConfiguration
            ),
            try SystemProxyServiceState(
                service: ethernet,
                protocolExists: false,
                configuration: nil
            ),
        ]
        let backend = FakeSystemProxyBackend(
            enabledServices: [wiFi, ethernet],
            states: originalStates
        )
        let manager = SystemProxyManager(backend: backend)

        let snapshot = try await manager.activate(
            endpoints: try LocalSystemProxyEndpoints(mixedPort: 7_890)
        )
        try await manager.restore(snapshot: snapshot)

        #expect(backend.currentStates == originalStates)
    }

    @Test("Codable snapshot persists and reloads all supported property-list types")
    func persistenceRoundTrip() async throws {
        let service = SystemProxyNetworkService(id: "wifi", name: "Wi-Fi")
        let configuration: SystemProxyDictionary = [
            "string": .string("value"),
            "integer": .integer(42),
            "double": .double(1.5),
            "bool": .bool(true),
            "data": .data(Data([0, 1, 2])),
            "date": .date(Date(timeIntervalSince1970: 123)),
            "array": .array([.string("a"), .integer(2)]),
            "dictionary": .dictionary(["nested": .bool(false)]),
        ]
        let state = try SystemProxyServiceState(
            service: service,
            protocolExists: true,
            configuration: configuration
        )
        let backend = FakeSystemProxyBackend(enabledServices: [service], states: [state])
        let manager = SystemProxyManager(backend: backend)
        let snapshot = SystemProxySnapshot(
            capturedAt: Date(timeIntervalSince1970: 1_700_000_000),
            services: [state]
        )
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let url = directory.appendingPathComponent("proxy-state.json")
        defer { try? FileManager.default.removeItem(at: directory) }

        try await manager.save(snapshot: snapshot, to: url)
        let reloaded = try await manager.loadSnapshot(from: url)

        #expect(reloaded == snapshot)
    }

    @Test("Concurrent activations are serialized by the manager actor")
    func concurrentOperationsAreSerialized() async throws {
        let service = SystemProxyNetworkService(id: "wifi", name: "Wi-Fi")
        let state = try SystemProxyServiceState(
            service: service,
            protocolExists: true,
            configuration: [:]
        )
        let backend = FakeSystemProxyBackend(
            enabledServices: [service],
            states: [state],
            operationDelay: 0.01
        )
        let manager = SystemProxyManager(backend: backend)

        async let first: Void = manager.apply(
            endpoints: try LocalSystemProxyEndpoints(mixedPort: 7_890)
        )
        async let second: Void = manager.apply(
            endpoints: try LocalSystemProxyEndpoints(mixedPort: 7_891)
        )
        _ = try await (first, second)

        #expect(backend.maximumConcurrentOperations == 1)
    }

    @Test("Endpoint validation reports actionable errors")
    func endpointValidation() {
        #expect(throws: SystemProxyError.self) {
            _ = try SystemProxyEndpoint(host: " ", port: 7_890)
        }
        #expect(throws: SystemProxyError.self) {
            _ = try SystemProxyEndpoint(port: 70_000)
        }
    }

    private var originalConfiguration: SystemProxyDictionary {
        [
            SystemProxyKeys.httpEnable: .integer(0),
            SystemProxyKeys.pacEnable: .integer(1),
            SystemProxyKeys.pacURL: .string("https://example.com/config.pac"),
            "ExceptionsList": .array([.string("localhost"), .string("*.local")]),
            "CustomFutureKey": .bool(true),
        ]
    }
}

private final class FakeSystemProxyBackend: SystemProxyBackend, @unchecked Sendable {
    private let lock = NSLock()
    private let enabledServices: [SystemProxyNetworkService]
    private let operationDelay: TimeInterval
    private var statesByID: [String: SystemProxyServiceState]
    private var activeOperations = 0
    private var maxActiveOperations = 0

    init(
        enabledServices: [SystemProxyNetworkService],
        states: [SystemProxyServiceState],
        operationDelay: TimeInterval = 0
    ) {
        self.enabledServices = enabledServices
        self.statesByID = Dictionary(uniqueKeysWithValues: states.map { ($0.service.id, $0) })
        self.operationDelay = operationDelay
    }

    var currentStates: [SystemProxyServiceState] {
        lock.withLock {
            enabledServices.compactMap { statesByID[$0.id] }
        }
    }

    var maximumConcurrentOperations: Int {
        lock.withLock { maxActiveOperations }
    }

    func enabledNetworkServices() throws -> [SystemProxyNetworkService] {
        trackedOperation { enabledServices }
    }

    func proxyStates(
        for services: [SystemProxyNetworkService]
    ) throws -> [SystemProxyServiceState] {
        try trackedOperation {
            try services.map { service in
                guard let state = statesByID[service.id] else {
                    throw SystemProxyError.serviceNotFound(service.id)
                }
                return state
            }
        }
    }

    func applyProxyStates(_ states: [SystemProxyServiceState]) throws {
        trackedOperation {
            lock.withLock {
                for state in states {
                    statesByID[state.service.id] = state
                }
            }
        }
    }

    private func trackedOperation<T>(_ operation: () throws -> T) rethrows -> T {
        lock.withLock {
            activeOperations += 1
            maxActiveOperations = max(maxActiveOperations, activeOperations)
        }
        defer {
            lock.withLock { activeOperations -= 1 }
        }
        if operationDelay > 0 {
            Thread.sleep(forTimeInterval: operationDelay)
        }
        return try operation()
    }
}
