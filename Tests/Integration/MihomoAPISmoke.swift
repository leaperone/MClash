import Foundation

@main
struct MihomoAPISmoke {
    static func main() async throws {
        let client = try MihomoAPIClient(
            baseURL: URL(string: "http://127.0.0.1:19090")!,
            secret: "integration-secret"
        )

        let version = try await client.fetchVersion()
        let config = try await client.fetchConfig()
        let proxies = try await client.fetchProxies()

        guard version.meta,
              version.version.hasPrefix("alpha-"),
              config.mixedPort == 17_890,
              proxies.proxies["DIRECT"] != nil else {
            throw SmokeFailure.unexpectedPayload
        }

        print(
            "API smoke passed: \(version.version), mixed-port \(config.mixedPort), "
                + "\(proxies.proxies.count) built-in proxies"
        )
    }
}

private enum SmokeFailure: Error {
    case unexpectedPayload
}
