import Foundation
import Testing
@testable import MClashApp

@Suite("networksetup system proxy backend")
struct NetworkSetupProxyBackendTests {
    @Test("Only networksetup-supported services are selected")
    func filtersUnsupportedServices() throws {
        let wiFi = SystemProxyNetworkService(id: "wifi", name: "Wi-Fi")
        let adapter = SystemProxyNetworkService(id: "adapter", name: "Ethernet Adapter (en5)")
        let runner = RecordingNetworkSetupRunner(
            serviceList: "An asterisk (*) denotes that a network service is disabled.\nWi-Fi\nEthernet\n"
        )
        let backend = NetworkSetupProxyBackend(
            reader: StaticProxyReader(services: [wiFi, adapter], states: []),
            runner: runner
        )

        let services = try backend.enabledNetworkServices()

        #expect(services == [wiFi])
    }

    @Test("Repeated reads reuse the networksetup service catalog")
    func cachesSupportedServiceNames() throws {
        let wiFi = SystemProxyNetworkService(id: "wifi", name: "Wi-Fi")
        let adapter = SystemProxyNetworkService(id: "adapter", name: "Virtual Adapter")
        let runner = RecordingNetworkSetupRunner(serviceList: "Wi-Fi\n")
        let backend = NetworkSetupProxyBackend(
            reader: StaticProxyReader(services: [wiFi, adapter], states: []),
            runner: runner
        )

        #expect(try backend.enabledNetworkServices() == [wiFi])
        #expect(try backend.enabledNetworkServices() == [wiFi])
        #expect(runner.commands == [["-listallnetworkservices"]])
    }

    @Test("HTTP, HTTPS, SOCKS, PAC, discovery, and bypass commands are explicit")
    func buildsCompleteProxyCommands() throws {
        let service = SystemProxyNetworkService(id: "wifi", name: "Wi-Fi")
        let state = try SystemProxyServiceState(
            service: service,
            protocolExists: true,
            configuration: [
                SystemProxyKeys.httpEnable: .integer(1),
                SystemProxyKeys.httpHost: .string("127.0.0.1"),
                SystemProxyKeys.httpPort: .integer(7_890),
                SystemProxyKeys.httpsEnable: .integer(1),
                SystemProxyKeys.httpsHost: .string("127.0.0.1"),
                SystemProxyKeys.httpsPort: .integer(7_890),
                SystemProxyKeys.socksEnable: .integer(1),
                SystemProxyKeys.socksHost: .string("127.0.0.1"),
                SystemProxyKeys.socksPort: .integer(7_891),
                SystemProxyKeys.pacEnable: .integer(0),
                SystemProxyKeys.pacURL: .string("http://127.0.0.1/proxy.pac"),
                SystemProxyKeys.autoDiscoveryEnable: .integer(0),
                SystemProxyKeys.exceptionsList: .array([.string("localhost"), .string("*.local")])
            ]
        )
        let runner = RecordingNetworkSetupRunner(serviceList: "Wi-Fi\n")
        let backend = NetworkSetupProxyBackend(
            reader: StaticProxyReader(services: [service], states: [state]),
            runner: runner
        )

        try backend.applyProxyStates([state])

        let commands = runner.commands
        #expect(commands.contains(["-setwebproxy", "Wi-Fi", "127.0.0.1", "7890"]))
        #expect(commands.contains(["-setwebproxystate", "Wi-Fi", "on"]))
        #expect(commands.contains(["-setsecurewebproxy", "Wi-Fi", "127.0.0.1", "7890"]))
        #expect(commands.contains(["-setsocksfirewallproxy", "Wi-Fi", "127.0.0.1", "7891"]))
        #expect(commands.contains(["-setautoproxystate", "Wi-Fi", "off"]))
        #expect(commands.contains(["-setproxyautodiscovery", "Wi-Fi", "off"]))
        #expect(commands.contains(["-setproxybypassdomains", "Wi-Fi", "localhost", "*.local"]))
    }

    @Test("A pre-commit permission failure removes the unused recovery snapshot")
    func lockFailureRemovesSnapshot() async throws {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "mclash-lock-failure-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let snapshotURL = root.appending(path: "snapshot.json")

        let manager = SystemProxyManager(backend: LockFailingProxyBackend())
        do {
            _ = try await manager.activate(
                endpoints: LocalSystemProxyEndpoints(mixedPort: 7_890),
                savingSnapshotTo: snapshotURL
            )
            Issue.record("Expected activation to fail")
        } catch let error as SystemProxyError {
            #expect(error == .lockFailed)
        }

        #expect(!FileManager.default.fileExists(atPath: snapshotURL.path))
    }

    @Test("A permission failure after a successful write is reported as a partial update")
    func partialWriteConvertsLockFailure() throws {
        let service = SystemProxyNetworkService(id: "wifi", name: "Wi-Fi")
        let state = try SystemProxyServiceState(
            service: service,
            protocolExists: true,
            configuration: [SystemProxyKeys.httpEnable: .integer(0)]
        )
        let runner = RecordingNetworkSetupRunner(
            serviceList: "Wi-Fi\n",
            failWriteAt: 2
        )
        let backend = NetworkSetupProxyBackend(
            reader: StaticProxyReader(services: [service], states: [state]),
            runner: runner
        )

        do {
            try backend.applyProxyStates([state])
            Issue.record("Expected the second write command to fail")
        } catch let error as SystemProxyError {
            guard case .networkSetupFailed = error else {
                Issue.record("Expected a recoverable partial-update error, received \(error)")
                return
            }
        }
    }

    @Test("A partial networksetup update retains the recovery snapshot")
    func partialWriteRetainsSnapshot() async throws {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "mclash-partial-write-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let snapshotURL = root.appending(path: "snapshot.json")
        let service = SystemProxyNetworkService(id: "wifi", name: "Wi-Fi")
        let state = try SystemProxyServiceState(
            service: service,
            protocolExists: true,
            configuration: [SystemProxyKeys.httpEnable: .integer(0)]
        )
        let runner = RecordingNetworkSetupRunner(
            serviceList: "Wi-Fi\n",
            failWriteAt: 2
        )
        let backend = NetworkSetupProxyBackend(
            reader: StaticProxyReader(services: [service], states: [state]),
            runner: runner
        )
        let manager = SystemProxyManager(backend: backend)

        do {
            _ = try await manager.activate(
                endpoints: LocalSystemProxyEndpoints(mixedPort: 7_890),
                savingSnapshotTo: snapshotURL
            )
            Issue.record("Expected activation to fail after a partial update")
        } catch let error as SystemProxyError {
            guard case .networkSetupFailed = error else {
                Issue.record("Expected a recoverable partial-update error, received \(error)")
                return
            }
        }

        #expect(FileManager.default.fileExists(atPath: snapshotURL.path))
    }

    @Test("An unavailable saved service prevents snapshot deletion")
    func unavailableServiceRetainsSnapshot() async throws {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "mclash-missing-service-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let snapshotURL = root.appending(path: "snapshot.json")
        let service = SystemProxyNetworkService(id: "wifi", name: "Wi-Fi")
        let state = try SystemProxyServiceState(
            service: service,
            protocolExists: true,
            configuration: [SystemProxyKeys.httpEnable: .integer(0)]
        )
        let runner = RecordingNetworkSetupRunner(serviceList: "Wi-Fi\n")
        let backend = NetworkSetupProxyBackend(
            reader: StaticProxyReader(services: [], states: []),
            runner: runner
        )
        let manager = SystemProxyManager(backend: backend)
        try await manager.save(
            snapshot: SystemProxySnapshot(services: [state]),
            to: snapshotURL
        )

        do {
            try await manager.restoreSnapshotAndRemove(from: snapshotURL)
            Issue.record("Expected restoration to fail for an unavailable service")
        } catch let error as SystemProxyError {
            #expect(error == .serviceNotFound(service.id))
        }

        #expect(FileManager.default.fileExists(atPath: snapshotURL.path))
        #expect(runner.commands == [["-listallnetworkservices"]])
    }
}

private final class RecordingNetworkSetupRunner: NetworkSetupCommandRunning, @unchecked Sendable {
    private let lock = NSLock()
    private let serviceList: String
    private let failWriteAt: Int?
    private var storedCommands: [[String]] = []
    private var writeCount = 0

    init(serviceList: String, failWriteAt: Int? = nil) {
        self.serviceList = serviceList
        self.failWriteAt = failWriteAt
    }

    var commands: [[String]] {
        lock.withLock { storedCommands }
    }

    func run(_ arguments: [String]) throws -> String {
        try lock.withLock {
            storedCommands.append(arguments)
            if arguments == ["-listallnetworkservices"] {
                return serviceList
            }
            writeCount += 1
            if writeCount == failWriteAt {
                throw SystemProxyError.lockFailed
            }
            return ""
        }
    }
}

private struct StaticProxyReader: SystemProxyBackend {
    let services: [SystemProxyNetworkService]
    let states: [SystemProxyServiceState]

    func enabledNetworkServices() throws -> [SystemProxyNetworkService] { services }

    func proxyStates(
        for services: [SystemProxyNetworkService]
    ) throws -> [SystemProxyServiceState] {
        states.filter { services.contains($0.service) }
    }

    func applyProxyStates(_ states: [SystemProxyServiceState]) throws {}
}

private struct LockFailingProxyBackend: SystemProxyBackend {
    private let service = SystemProxyNetworkService(id: "wifi", name: "Wi-Fi")

    func enabledNetworkServices() throws -> [SystemProxyNetworkService] { [service] }

    func proxyStates(
        for services: [SystemProxyNetworkService]
    ) throws -> [SystemProxyServiceState] {
        [
            try SystemProxyServiceState(
                service: service,
                protocolExists: true,
                configuration: [SystemProxyKeys.httpEnable: .integer(0)]
            )
        ]
    }

    func applyProxyStates(_ states: [SystemProxyServiceState]) throws {
        throw SystemProxyError.lockFailed
    }
}
