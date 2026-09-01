import Foundation
import Testing
@testable import MClashApp

@Suite("Application instance lock", .serialized)
struct ApplicationInstanceLockTests {
    @Test("Development namespace is opt-in and path-safe")
    func developmentNamespace() {
        #expect(ApplicationInstanceLock.resolvedNamespace(environment: [:]) == "one.leaper.mclash")
        #expect(ApplicationInstanceLock.resolvedNamespace(
            environment: ["MCLASH_INSTANCE_NAMESPACE": "one.leaper.mclash-dev"]
        ) == "one.leaper.mclash-dev")
        #expect(ApplicationInstanceLock.resolvedNamespace(
            environment: ["MCLASH_INSTANCE_NAMESPACE": "../production"]
        ) == "one.leaper.mclash")
    }

    @Test("Only one process owner can hold the application lock")
    func lockHasSingleOwner() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "mclash-instance-lock-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("instance.lock")

        let first = ApplicationInstanceLock(lockURL: url)
        let second = ApplicationInstanceLock(lockURL: url)

        #expect(first.isOwner)
        #expect(!second.isOwner)

        first.release()
        let replacement = ApplicationInstanceLock(lockURL: url)
        #expect(replacement.isOwner)
    }
}
