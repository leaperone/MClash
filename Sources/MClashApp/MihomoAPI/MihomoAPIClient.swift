import Foundation

public struct MihomoAPIConfiguration: Equatable, Sendable {
    public let baseURL: URL
    public let secret: String
    public let requestTimeout: TimeInterval

    public init(
        baseURL: URL,
        secret: String,
        requestTimeout: TimeInterval = 15
    ) {
        self.baseURL = baseURL
        self.secret = secret
        self.requestTimeout = requestTimeout
    }
}

public enum MihomoAPIError: Error, Equatable, Sendable {
    case invalidBaseURL
    case invalidArgument(String)
    case invalidResponse
    case emptyResponse
    case httpStatus(code: Int, message: String?)
    case invalidWebSocketMessage
}

extension MihomoAPIError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidBaseURL:
            "The mihomo controller URL is invalid."
        case let .invalidArgument(message):
            message
        case .invalidResponse:
            "The mihomo controller returned an invalid HTTP response."
        case .emptyResponse:
            "The mihomo controller returned an empty response."
        case let .httpStatus(code, message):
            message.map { "mihomo returned HTTP \(code): \($0)" } ?? "mihomo returned HTTP \(code)."
        case .invalidWebSocketMessage:
            "The mihomo controller sent an unsupported WebSocket message."
        }
    }
}

public actor MihomoAPIClient {
    private let configuration: MihomoAPIConfiguration
    private let session: URLSession

    public init(
        configuration: MihomoAPIConfiguration,
        session: URLSession = .shared
    ) throws {
        guard
            let scheme = configuration.baseURL.scheme?.lowercased(),
            scheme == "http" || scheme == "https",
            configuration.baseURL.host != nil,
            configuration.requestTimeout > 0
        else {
            throw MihomoAPIError.invalidBaseURL
        }

        self.configuration = configuration
        self.session = session
    }

    public init(
        baseURL: URL,
        secret: String,
        requestTimeout: TimeInterval = 15,
        session: URLSession = .shared
    ) throws {
        try self.init(
            configuration: MihomoAPIConfiguration(
                baseURL: baseURL,
                secret: secret,
                requestTimeout: requestTimeout
            ),
            session: session
        )
    }

    public func fetchVersion() async throws -> MihomoVersion {
        try await get(["version"])
    }

    public func fetchConfig() async throws -> MihomoConfig {
        try await get(["configs"])
    }

    public func fetchRules() async throws -> MihomoRuleCollection {
        try await get(["rules"])
    }

    public func fetchProxies() async throws -> MihomoProxyCollection {
        try await get(["proxies"])
    }

    public func fetchProxy(named name: String) async throws -> MihomoProxy {
        try requireNonEmpty(name, argument: "Proxy name")
        return try await get(["proxies", name])
    }

    public func selectProxy(group: String, proxy: String) async throws {
        try requireNonEmpty(group, argument: "Proxy group name")
        try requireNonEmpty(proxy, argument: "Proxy name")
        try await sendNoContent(
            method: "PUT",
            pathComponents: ["proxies", group],
            body: ProxySelectionRequest(name: proxy)
        )
    }

    public func clearProxyOverride(group: String) async throws {
        try requireNonEmpty(group, argument: "Proxy group name")
        try await sendNoContent(
            method: "DELETE",
            pathComponents: ["proxies", group]
        )
    }

    public func fetchProxyProviders() async throws -> MihomoProxyProviderCollection {
        try await get(["providers", "proxies"])
    }

    public func fetchProxyProvider(named name: String) async throws -> MihomoProxyProvider {
        try requireNonEmpty(name, argument: "Proxy provider name")
        return try await get(["providers", "proxies", name])
    }

    public func updateProxyProvider(named name: String) async throws {
        try requireNonEmpty(name, argument: "Proxy provider name")
        try await sendNoContent(
            method: "PUT",
            pathComponents: ["providers", "proxies", name]
        )
    }

    public func healthCheckProxyProvider(named name: String) async throws {
        try requireNonEmpty(name, argument: "Proxy provider name")
        try await sendNoContent(
            method: "GET",
            pathComponents: ["providers", "proxies", name, "healthcheck"]
        )
    }

    public func fetchRuleProviders() async throws -> MihomoRuleProviderCollection {
        try await get(["providers", "rules"])
    }

    public func updateRuleProvider(named name: String) async throws {
        try requireNonEmpty(name, argument: "Rule provider name")
        try await sendNoContent(
            method: "PUT",
            pathComponents: ["providers", "rules", name]
        )
    }

    public func measureDelay(
        proxy: String,
        targetURL: URL,
        timeoutMilliseconds: Int = 5_000,
        expectedStatus: String? = nil
    ) async throws -> Int {
        try requireNonEmpty(proxy, argument: "Proxy name")
        try validateDelayArguments(targetURL: targetURL, timeoutMilliseconds: timeoutMilliseconds)

        var query = delayQuery(
            targetURL: targetURL,
            timeoutMilliseconds: timeoutMilliseconds,
            expectedStatus: expectedStatus
        )
        // Alpha accepts an empty expected range, but including it keeps parity with its dashboard API.
        if expectedStatus == nil {
            query.append(URLQueryItem(name: "expected", value: ""))
        }

        let result: MihomoDelayResult = try await get(
            ["proxies", proxy, "delay"],
            queryItems: query
        )
        return result.delay
    }

    /// Reloads configuration from a path visible to the mihomo process.
    /// Pass `nil` to ask Alpha to reload its default configuration path.
    public func reloadConfig(fromPath path: String? = nil, force: Bool = false) async throws {
        try await reloadConfig(
            request: ConfigReloadRequest(path: path ?? "", payload: ""),
            force: force
        )
    }

    /// Parses and reloads configuration directly from YAML text.
    public func reloadConfig(payload: String, force: Bool = false) async throws {
        try requireNonEmpty(payload, argument: "Configuration payload")
        try await reloadConfig(
            request: ConfigReloadRequest(path: "", payload: payload),
            force: force
        )
    }

    public func patchConfig(_ patch: MihomoConfigPatch) async throws {
        try await sendNoContent(
            method: "PATCH",
            pathComponents: ["configs"],
            body: patch
        )
    }

    public func fetchConnections() async throws -> MihomoConnectionSnapshot {
        try await get(["connections"])
    }

    public func closeConnection(id: String) async throws {
        try requireNonEmpty(id, argument: "Connection ID")
        try await sendNoContent(method: "DELETE", pathComponents: ["connections", id])
    }

    public func closeAllConnections() async throws {
        try await sendNoContent(method: "DELETE", pathComponents: ["connections"])
    }

    public func trafficStream() throws -> AsyncThrowingStream<MihomoTraffic, Error> {
        try webSocketStream(
            pathComponents: ["traffic"],
            bufferingPolicy: .bufferingNewest(1)
        )
    }

    public func logStream(
        minimumLevel: MihomoLogLevel = .info
    ) throws -> AsyncThrowingStream<MihomoLogEntry, Error> {
        try webSocketStream(
            pathComponents: ["logs"],
            queryItems: [URLQueryItem(name: "level", value: minimumLevel.rawValue)],
            bufferingPolicy: .bufferingNewest(250)
        )
    }

    public func structuredLogStream(
        minimumLevel: MihomoLogLevel = .info
    ) throws -> AsyncThrowingStream<MihomoStructuredLogEntry, Error> {
        try webSocketStream(
            pathComponents: ["logs"],
            queryItems: [
                URLQueryItem(name: "level", value: minimumLevel.rawValue),
                URLQueryItem(name: "format", value: "structured"),
            ],
            bufferingPolicy: .bufferingNewest(250)
        )
    }

    public func connectionStream(
        intervalMilliseconds: Int = 1_000
    ) throws -> AsyncThrowingStream<MihomoConnectionSnapshot, Error> {
        guard intervalMilliseconds > 0 else {
            throw MihomoAPIError.invalidArgument("Connection stream interval must be greater than zero.")
        }
        return try webSocketStream(
            pathComponents: ["connections"],
            queryItems: [URLQueryItem(name: "interval", value: String(intervalMilliseconds))],
            bufferingPolicy: .bufferingNewest(1)
        )
    }

    private func reloadConfig(request: ConfigReloadRequest, force: Bool) async throws {
        try await sendNoContent(
            method: "PUT",
            pathComponents: ["configs"],
            queryItems: [URLQueryItem(name: "force", value: force ? "true" : "false")],
            body: request
        )
    }

    private func get<Response: Decodable & Sendable>(
        _ pathComponents: [String],
        queryItems: [URLQueryItem] = []
    ) async throws -> Response {
        let request = try makeRequest(
            method: "GET",
            pathComponents: pathComponents,
            queryItems: queryItems
        )
        let data = try await perform(request)
        guard !data.isEmpty else {
            throw MihomoAPIError.emptyResponse
        }
        return try JSONDecoder().decode(Response.self, from: data)
    }

    private func sendNoContent(
        method: String,
        pathComponents: [String],
        queryItems: [URLQueryItem] = []
    ) async throws {
        let request = try makeRequest(
            method: method,
            pathComponents: pathComponents,
            queryItems: queryItems
        )
        _ = try await perform(request)
    }

    private func sendNoContent<Body: Encodable>(
        method: String,
        pathComponents: [String],
        queryItems: [URLQueryItem] = [],
        body: Body
    ) async throws {
        var request = try makeRequest(
            method: method,
            pathComponents: pathComponents,
            queryItems: queryItems
        )
        request.httpBody = try JSONEncoder().encode(body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        _ = try await perform(request)
    }

    private func perform(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw MihomoAPIError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            let message = try? JSONDecoder().decode(MihomoErrorResponse.self, from: data).message
            throw MihomoAPIError.httpStatus(code: httpResponse.statusCode, message: message)
        }
        return data
    }

    private func webSocketStream<Element: Decodable & Sendable>(
        pathComponents: [String],
        queryItems: [URLQueryItem] = [],
        bufferingPolicy: AsyncThrowingStream<Element, Error>.Continuation.BufferingPolicy =
            .unbounded
    ) throws -> AsyncThrowingStream<Element, Error> {
        let request = try makeRequest(
            method: "GET",
            pathComponents: pathComponents,
            queryItems: queryItems
        )
        let socket = session.webSocketTask(with: request)

        return AsyncThrowingStream(bufferingPolicy: bufferingPolicy) { continuation in
            let receiveTask = Task {
                socket.resume()
                do {
                    while !Task.isCancelled {
                        let message = try await socket.receive()
                        let data: Data
                        switch message {
                        case let .data(value):
                            data = value
                        case let .string(value):
                            guard let value = value.data(using: .utf8) else {
                                throw MihomoAPIError.invalidWebSocketMessage
                            }
                            data = value
                        @unknown default:
                            throw MihomoAPIError.invalidWebSocketMessage
                        }
                        continuation.yield(try JSONDecoder().decode(Element.self, from: data))
                    }
                    socket.cancel(with: .goingAway, reason: nil)
                    continuation.finish()
                } catch is CancellationError {
                    socket.cancel(with: .goingAway, reason: nil)
                    continuation.finish()
                } catch {
                    socket.cancel(with: .goingAway, reason: nil)
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { @Sendable _ in
                receiveTask.cancel()
                socket.cancel(with: .goingAway, reason: nil)
            }
        }
    }

    private func makeRequest(
        method: String,
        pathComponents: [String],
        queryItems: [URLQueryItem] = []
    ) throws -> URLRequest {
        guard var components = URLComponents(
            url: configuration.baseURL,
            resolvingAgainstBaseURL: false
        ) else {
            throw MihomoAPIError.invalidBaseURL
        }

        var path = components.percentEncodedPath
        while path.hasSuffix("/") {
            path.removeLast()
        }
        for component in pathComponents {
            path += "/" + Self.encodePathComponent(component)
        }
        components.percentEncodedPath = path
        components.queryItems = queryItems.isEmpty ? nil : queryItems

        guard let url = components.url else {
            throw MihomoAPIError.invalidBaseURL
        }

        var request = URLRequest(url: url, timeoutInterval: configuration.requestTimeout)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if !configuration.secret.isEmpty {
            request.setValue("Bearer \(configuration.secret)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    private nonisolated static func encodePathComponent(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    private func delayQuery(
        targetURL: URL,
        timeoutMilliseconds: Int,
        expectedStatus: String?
    ) -> [URLQueryItem] {
        var query = [
            URLQueryItem(name: "url", value: targetURL.absoluteString),
            URLQueryItem(name: "timeout", value: String(timeoutMilliseconds)),
        ]
        if let expectedStatus {
            query.append(URLQueryItem(name: "expected", value: expectedStatus))
        }
        return query
    }

    private func validateDelayArguments(
        targetURL: URL,
        timeoutMilliseconds: Int
    ) throws {
        guard let scheme = targetURL.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            throw MihomoAPIError.invalidArgument("Delay test URL must use HTTP or HTTPS.")
        }
        guard timeoutMilliseconds > 0 else {
            throw MihomoAPIError.invalidArgument("Delay test timeout must be greater than zero.")
        }
    }

    private func requireNonEmpty(_ value: String, argument: String) throws {
        guard !value.isEmpty else {
            throw MihomoAPIError.invalidArgument("\(argument) must not be empty.")
        }
    }
}

private struct ProxySelectionRequest: Encodable {
    let name: String
}

private struct ConfigReloadRequest: Encodable {
    let path: String
    let payload: String
}

private struct MihomoErrorResponse: Decodable {
    let message: String
}
