import Foundation

@main
struct AppModelSmoke {
    @MainActor
    static func main() async throws {
        let repository = URL(filePath: FileManager.default.currentDirectoryPath)
        let model = AppModel(secretStore: StaticSecretProvider())
        model.explicitCoreURL = repository.appending(
            path: "Sources/MClashApp/Resources/Core/mihomo-alpha-darwin-arm64"
        )
        model.activeConfigURL = repository.appending(path: "Tests/Fixtures/minimal.yaml")

        do {
            await model.connect()

            for _ in 0..<30 where !model.isConnected || model.runtimeConfig == nil {
                try await Task.sleep(for: .milliseconds(100))
            }

            guard model.isConnected,
                  model.runningSession?.version.hasPrefix("alpha-") == true,
                  model.runtimeConfig?.mixedPort == 17_890 else {
                let details = [
                    "state=\(String(describing: model.coreState))",
                    "error=\(model.errorMessage ?? "none")",
                    "runtime=\(model.runtimeConfig?.mixedPort.description ?? "none")",
                    "lastLog=\(model.logs.last?.message ?? "none")"
                ].joined(separator: ", ")
                throw SmokeFailure.didNotConnect(details)
            }

            await model.disconnect()
            guard !model.isConnected else { throw SmokeFailure.didNotDisconnect }

            print("App model smoke passed")
        } catch {
            await model.shutdown()
            throw error
        }
    }
}

private enum SmokeFailure: Error {
    case didNotConnect(String)
    case didNotDisconnect
}

private struct StaticSecretProvider: CoreSecretProviding {
    func loadOrCreate() throws -> String {
        "app-model-smoke-secret"
    }
}
