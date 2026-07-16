import Foundation
import Testing
@testable import MClashApp

@Suite("Mihomo API client", .serialized)
struct MihomoAPIClientTests {
    private func resetStub() {
        StubURLProtocol.reset()
    }

    @Test
    func fetchVersionUsesBearerAuthentication() async throws {
        resetStub()
        defer { resetStub() }
        StubURLProtocol.install { request in
            let data = Data(#"{"meta":true,"version":"1.19.10-alpha"}"#.utf8)
            return (try Self.response(for: request, statusCode: 200), data)
        }
        let client = try makeClient(secret: "top-secret")

        let version = try await client.fetchVersion()
        let request = try #require(StubURLProtocol.recordedRequests.last)

        #expect(version.version == "1.19.10-alpha")
        #expect(request.httpMethod == "GET")
        #expect(request.url?.path == "/api/version")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer top-secret")
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
    }

    @Test
    func selectProxyEscapesGroupNameAndEncodesBody() async throws {
        resetStub()
        defer { resetStub() }
        StubURLProtocol.install { request in
            (try Self.response(for: request, statusCode: 204), Data())
        }
        let client = try makeClient()

        try await client.selectProxy(group: "香港 / 自动", proxy: "节点 A")
        let request = try #require(StubURLProtocol.recordedRequests.last)
        let body = try #require(request.httpBody)
        let object = try #require(JSONSerialization.jsonObject(with: body) as? [String: String])

        let encodedPath = request.url.flatMap {
            URLComponents(url: $0, resolvingAgainstBaseURL: false)?.percentEncodedPath
        }
        #expect(encodedPath == "/api/proxies/%E9%A6%99%E6%B8%AF%20%2F%20%E8%87%AA%E5%8A%A8")
        #expect(request.httpMethod == "PUT")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(object == ["name": "节点 A"])
    }

    @Test
    func delayRequestAndPayloadConfigReloadMatchAlphaRoutes() async throws {
        resetStub()
        defer { resetStub() }
        StubURLProtocol.install { request in
            if request.url?.path.hasSuffix("/delay") == true {
                return (
                    try Self.response(for: request, statusCode: 200),
                    Data(#"{"delay":87}"#.utf8)
                )
            }
            return (try Self.response(for: request, statusCode: 204), Data())
        }
        let client = try makeClient()

        let delay = try await client.measureDelay(
            proxy: "Node A",
            targetURL: try #require(URL(string: "https://cp.cloudflare.com/generate_204")),
            timeoutMilliseconds: 3_000,
            expectedStatus: "204"
        )
        try await client.reloadConfig(payload: "mixed-port: 7890\n", force: true)

        #expect(delay == 87)
        let requests = StubURLProtocol.recordedRequests
        #expect(requests.count == 2)

        let delayItems = URLComponents(
            url: try #require(requests[0].url),
            resolvingAgainstBaseURL: false
        )?.queryItems
        #expect(delayItems?.first(where: { $0.name == "timeout" })?.value == "3000")
        #expect(delayItems?.first(where: { $0.name == "expected" })?.value == "204")

        let reloadRequest = requests[1]
        #expect(reloadRequest.url?.path == "/api/configs")
        #expect(reloadRequest.url?.query == "force=true")
        let reloadBody = try #require(reloadRequest.httpBody)
        let reloadObject = try #require(
            JSONSerialization.jsonObject(with: reloadBody) as? [String: String]
        )
        #expect(reloadObject["path"] == "")
        #expect(reloadObject["payload"] == "mixed-port: 7890\n")
    }

    @Test
    func httpErrorSurfacesMihomoMessage() async throws {
        resetStub()
        defer { resetStub() }
        StubURLProtocol.install { request in
            (
                try Self.response(for: request, statusCode: 401),
                Data(#"{"message":"Unauthorized"}"#.utf8)
            )
        }
        let client = try makeClient()

        do {
            _ = try await client.fetchVersion()
            Issue.record("Expected an HTTP error")
        } catch let error as MihomoAPIError {
            #expect(error == .httpStatus(code: 401, message: "Unauthorized"))
        } catch {
            Issue.record("Expected MihomoAPIError, got \(error)")
        }
    }

    private func makeClient(secret: String = "secret") throws -> MihomoAPIClient {
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [StubURLProtocol.self]
        let session = URLSession(configuration: sessionConfiguration)
        return try MihomoAPIClient(
            baseURL: try #require(URL(string: "http://127.0.0.1:9090/api/")),
            secret: secret,
            session: session
        )
    }

    private nonisolated static func response(
        for request: URLRequest,
        statusCode: Int
    ) throws -> HTTPURLResponse {
        guard let url = request.url,
              let response = HTTPURLResponse(
                  url: url,
                  statusCode: statusCode,
                  httpVersion: "HTTP/1.1",
                  headerFields: ["Content-Type": "application/json"]
              )
        else {
            throw MihomoAPIError.invalidResponse
        }
        return response
    }
}

private final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)

    private static let lock = NSLock()
    nonisolated(unsafe) private static var handler: Handler?
    nonisolated(unsafe) private static var requests: [URLRequest] = []

    static var recordedRequests: [URLRequest] {
        lock.withLock { requests }
    }

    static func install(_ handler: @escaping Handler) {
        lock.withLock {
            self.handler = handler
            requests = []
        }
    }

    static func reset() {
        lock.withLock {
            handler = nil
            requests = []
        }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let recordedRequest = Self.materializeBody(in: request)
        let handler = Self.lock.withLock { () -> Handler? in
            Self.requests.append(recordedRequest)
            return Self.handler
        }

        guard let handler else {
            client?.urlProtocol(self, didFailWithError: MihomoAPIError.invalidResponse)
            return
        }

        do {
            let (response, data) = try handler(recordedRequest)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}

    private static func materializeBody(in request: URLRequest) -> URLRequest {
        guard request.httpBody == nil, let stream = request.httpBodyStream else {
            return request
        }

        stream.open()
        defer { stream.close() }

        var body = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            body.append(buffer, count: count)
        }

        var copy = request
        copy.httpBodyStream = nil
        copy.httpBody = body
        return copy
    }
}
