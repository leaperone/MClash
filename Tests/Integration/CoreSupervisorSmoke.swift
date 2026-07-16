import Foundation

@main
struct CoreSupervisorSmoke {
    static func main() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "mclash-core-smoke-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }

        let repository = URL(filePath: FileManager.default.currentDirectoryPath)
        let configuration = CoreLaunchConfiguration(
            binaryURL: repository.appending(
                path: "Sources/MClashApp/Resources/Core/\(CoreBinaryLocator.bundledResourceName)"
            ),
            homeDirectory: root,
            configURL: repository.appending(path: "Tests/Fixtures/minimal.yaml"),
            controllerPort: 19_092,
            secret: "core-supervisor-smoke"
        )

        let supervisor = CoreSupervisor()
        try await supervisor.start(configuration)

        guard case let .running(session) = await supervisor.state(),
              session.version.hasPrefix("alpha-") else {
            throw SmokeFailure.notRunning
        }

        await supervisor.stop()
        guard case .stopped = await supervisor.state() else {
            throw SmokeFailure.didNotStop
        }

        print("Core supervisor smoke passed: \(session.version)")
    }
}

private enum SmokeFailure: Error {
    case notRunning
    case didNotStop
}
