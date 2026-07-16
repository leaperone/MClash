import Foundation
import Testing
@testable import MClashApp

@Suite("App model network safety")
struct AppModelSafetyTests {
    @MainActor
    @Test("A failed proxy activation without a snapshot does not lock the application")
    func failedActivationWithoutSnapshotIsDismissible() throws {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "mclash-no-recovery-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let layout = ProfileDirectoryLayout(rootDirectory: root)
        try layout.createDirectories()
        let model = AppModel(
            systemProxyManager: SystemProxyManager(backend: RestoreBackend(failsRestore: false)),
            profileDirectoryLayout: layout
        )
        model.systemProxyState = .failed("Permission was not granted.")
        model.errorMessage = "Permission was not granted."

        #expect(!model.systemProxyRecoveryRequired)
        #expect(!model.systemProxyEnabled)
        #expect(model.canPerform(.connection))
    }

    @MainActor
    @Test("Shutdown is cancelled when the previous system proxy cannot be restored")
    func shutdownStopsWhenProxyRestoreFails() async throws {
        let fixture = try Fixture(failsRestore: true)
        defer { fixture.cleanup() }

        let canTerminate = await fixture.model.shutdown()

        #expect(!canTerminate)
        #expect(FileManager.default.fileExists(atPath: fixture.snapshotURL.path))
        guard case .failed = fixture.model.systemProxyState else {
            Issue.record("Expected a failed system proxy state")
            return
        }
    }

    @MainActor
    @Test("Successful shutdown restores and removes the persisted system proxy snapshot")
    func shutdownRestoresProxySnapshot() async throws {
        let fixture = try Fixture(failsRestore: false)
        defer { fixture.cleanup() }

        let canTerminate = await fixture.model.shutdown()

        #expect(canTerminate)
        #expect(!FileManager.default.fileExists(atPath: fixture.snapshotURL.path))
        #expect(fixture.model.systemProxyState == .off)
        #expect(fixture.backend.applyCount == 1)
    }
}

@MainActor
private struct Fixture {
    let root: URL
    let snapshotURL: URL
    let backend: RestoreBackend
    let model: AppModel

    init(failsRestore: Bool) throws {
        root = FileManager.default.temporaryDirectory
            .appending(path: "mclash-app-model-\(UUID().uuidString)", directoryHint: .isDirectory)
        let layout = ProfileDirectoryLayout(rootDirectory: root)
        try layout.createDirectories()

        let service = SystemProxyNetworkService(id: "wifi", name: "Wi-Fi")
        let state = try SystemProxyServiceState(
            service: service,
            protocolExists: true,
            configuration: [SystemProxyKeys.httpEnable: .integer(0)]
        )
        backend = RestoreBackend(failsRestore: failsRestore)
        let manager = SystemProxyManager(backend: backend)
        snapshotURL = layout.stateDirectory.appending(path: "system-proxy-snapshot.json")
        try JSONEncoder().encode(SystemProxySnapshot(services: [state]))
            .write(to: snapshotURL, options: .atomic)

        model = AppModel(
            systemProxyManager: manager,
            profileDirectoryLayout: layout
        )
        model.systemProxyState = .on
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }
}

private final class RestoreBackend: SystemProxyBackend, @unchecked Sendable {
    private let lock = NSLock()
    private let failsRestore: Bool
    private var storedApplyCount = 0

    init(failsRestore: Bool) {
        self.failsRestore = failsRestore
    }

    var applyCount: Int {
        lock.withLock { storedApplyCount }
    }

    func enabledNetworkServices() throws -> [SystemProxyNetworkService] { [] }

    func proxyStates(
        for services: [SystemProxyNetworkService]
    ) throws -> [SystemProxyServiceState] {
        []
    }

    func applyProxyStates(_ states: [SystemProxyServiceState]) throws {
        if failsRestore { throw SystemProxyError.applyFailed }
        lock.withLock { storedApplyCount += 1 }
    }
}
