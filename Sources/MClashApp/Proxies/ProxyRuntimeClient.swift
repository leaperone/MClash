import Foundation

public enum ProxyRuntimeBackend: String, Codable, Sendable {
    case xray
    case mihomoCompatibility
}

/// Operations used by the existing workbench. The response models retain
/// their wire names while the runtime implementation changes.
public protocol ProxyRuntimeClient: Actor {
    var backend: ProxyRuntimeBackend { get }
    func fetchVersion() async throws -> MihomoVersion
    func fetchConfig() async throws -> MihomoConfig
    func fetchRules() async throws -> MihomoRuleCollection
    func fetchProxies() async throws -> MihomoProxyCollection
    func fetchProxy(named name: String) async throws -> MihomoProxy
    func selectProxy(group: String, proxy: String) async throws
    func clearProxyOverride(group: String) async throws
    func fetchProxyProviders() async throws -> MihomoProxyProviderCollection
    func fetchProxyProvider(named name: String) async throws -> MihomoProxyProvider
    func updateProxyProvider(named name: String) async throws
    func healthCheckProxyProvider(named name: String) async throws
    func fetchRuleProviders() async throws -> MihomoRuleProviderCollection
    func updateRuleProvider(named name: String) async throws
    func measureDelay(
        proxy: String,
        targetURL: URL,
        timeoutMilliseconds: Int,
        expectedStatus: String?
    ) async throws -> Int
    func reloadConfig(fromPath path: String?, force: Bool) async throws
    func reloadConfig(payload: String, force: Bool) async throws
    func patchConfig(_ patch: MihomoConfigPatch) async throws
    func fetchConnections() async throws -> MihomoConnectionSnapshot
    func closeConnection(id: String) async throws
    func closeAllConnections() async throws
    func trafficStream() throws -> AsyncThrowingStream<MihomoTraffic, Error>
    func logStream(minimumLevel: MihomoLogLevel) throws -> AsyncThrowingStream<MihomoLogEntry, Error>
    func structuredLogStream(minimumLevel: MihomoLogLevel) throws -> AsyncThrowingStream<MihomoStructuredLogEntry, Error>
    func connectionStream(intervalMilliseconds: Int) throws -> AsyncThrowingStream<MihomoConnectionSnapshot, Error>
}

extension MihomoAPIClient: ProxyRuntimeClient {
    public var backend: ProxyRuntimeBackend { .mihomoCompatibility }
}

public extension ProxyRuntimeClient {
    func measureDelay(proxy: String, targetURL: URL, expectedStatus: String?) async throws -> Int {
        try await measureDelay(
            proxy: proxy,
            targetURL: targetURL,
            timeoutMilliseconds: 5_000,
            expectedStatus: expectedStatus
        )
    }

    func measureDelay(
        proxy: String,
        targetURL: URL,
        timeoutMilliseconds: Int = 5_000
    ) async throws -> Int {
        try await measureDelay(
            proxy: proxy,
            targetURL: targetURL,
            timeoutMilliseconds: timeoutMilliseconds,
            expectedStatus: nil
        )
    }

    func reloadConfig(fromPath path: String? = nil) async throws {
        try await reloadConfig(fromPath: path, force: false)
    }

    func reloadConfig(payload: String) async throws {
        try await reloadConfig(payload: payload, force: false)
    }

    func logStream() throws -> AsyncThrowingStream<MihomoLogEntry, Error> {
        try logStream(minimumLevel: .info)
    }

    func structuredLogStream() throws -> AsyncThrowingStream<MihomoStructuredLogEntry, Error> {
        try structuredLogStream(minimumLevel: .info)
    }

    func connectionStream() throws -> AsyncThrowingStream<MihomoConnectionSnapshot, Error> {
        try connectionStream(intervalMilliseconds: 1_000)
    }
}
