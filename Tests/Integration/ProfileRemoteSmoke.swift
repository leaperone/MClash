import Foundation

@main
struct ProfileRemoteSmoke {
    static func main() async throws {
        guard let rawURL = ProcessInfo.processInfo.environment["MCLASH_TEST_SUBSCRIPTION"],
              let subscriptionURL = URL(string: rawURL),
              let corePath = ProcessInfo.processInfo.environment["MCLASH_TEST_CORE"] else {
            throw SmokeFailure.missingEnvironment
        }

        let root = FileManager.default.temporaryDirectory
            .appending(path: "mclash-profile-smoke-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }

        let layout = ProfileDirectoryLayout(rootDirectory: root)
        let store = try ProfileStore(layout: layout)
        let validator = ClosureProfileValidator { configurationURL in
            try validate(
                configurationURL: configurationURL,
                coreURL: URL(filePath: corePath),
                homeURL: root.appending(path: "CoreHome", directoryHint: .isDirectory)
            )
        }

        let profile = try await store.createRemoteProfile(
            name: "Private integration profile",
            subscriptionURL: subscriptionURL,
            validator: validator
        )
        let activation = try await store.activateProfile(profile.id, validator: validator)
        _ = try await store.refreshRemoteProfile(profile.id, validator: validator)

        let count = try await store.profiles().count
        let bytes = try Data(contentsOf: activation.configurationURL).count
        guard count == 1, bytes > 0 else { throw SmokeFailure.unexpectedResult }

        print("Remote profile smoke passed: \(count) profile, \(bytes) validated bytes")
    }

    private static func validate(
        configurationURL: URL,
        coreURL: URL,
        homeURL: URL
    ) throws {
        try FileManager.default.createDirectory(at: homeURL, withIntermediateDirectories: true)

        let process = Process()
        let output = Pipe()
        process.executableURL = coreURL
        process.arguments = ["-t", "-d", homeURL.path, "-f", configurationURL.path]
        process.standardOutput = output
        process.standardError = output
        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw SmokeFailure.validationFailed
        }
    }
}

private enum SmokeFailure: Error {
    case missingEnvironment
    case unexpectedResult
    case validationFailed
}
