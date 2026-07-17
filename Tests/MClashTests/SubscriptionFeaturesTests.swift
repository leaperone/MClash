import Foundation
import Testing
@testable import MClashApp

@Suite("Subscription features")
struct SubscriptionFeaturesTests {
    @Test("Subscription response headers are parsed defensively")
    func parsesSubscriptionHeaders() throws {
        let usage = try #require(
            URLSessionSubscriptionDownloader.subscriptionUsage(
                from: "upload=1024; download=2048; total=8192; expire=1893456000"
            )
        )
        #expect(usage.upload == 1_024)
        #expect(usage.download == 2_048)
        #expect(usage.used == 3_072)
        #expect(usage.total == 8_192)
        #expect(usage.expiresAt == Date(timeIntervalSince1970: 1_893_456_000))
        #expect(URLSessionSubscriptionDownloader.updateInterval(from: " 24 ") == 24)
        #expect(URLSessionSubscriptionDownloader.updateInterval(from: "0") == nil)
        #expect(
            URLSessionSubscriptionDownloader.webPageURL(from: "javascript:alert(1)") == nil
        )
    }

    @Test("Legacy remote metadata defaults automatic updates on")
    func decodesLegacyMetadata() throws {
        let data = Data(
            #"{"url":"https:\/\/example.com\/profile.yaml","lastCheckedAt":"2026-07-17T00:00:00Z"}"#.utf8
        )
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let metadata = try decoder.decode(RemoteSubscriptionMetadata.self, from: data)
        let lastCheckedAt = try #require(metadata.lastCheckedAt)
        #expect(metadata.automaticUpdatesEnabled)
        #expect(metadata.effectiveUpdateIntervalHours == 24)
        #expect(
            metadata.nextAutomaticUpdateAt()
                == lastCheckedAt.addingTimeInterval(24 * 3_600)
        )
    }

    @Test("Subscription downloads enforce declared and streamed byte limits")
    func enforcesBoundedDownloads() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BoundedDownloadURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let downloader = URLSessionSubscriptionDownloader(
            session: session,
            maximumResponseSize: 4
        )

        await #expect(throws: SubscriptionDownloadError.responseTooLarge(4)) {
            _ = try await downloader.download(
                URLRequest(url: URL(string: "https://example.test/declared-too-large")!)
            )
        }
        await #expect(throws: SubscriptionDownloadError.responseTooLarge(4)) {
            _ = try await downloader.download(
                URLRequest(url: URL(string: "https://example.test/streamed-too-large")!)
            )
        }

        let accepted = try await downloader.download(
            URLRequest(url: URL(string: "https://example.test/accepted")!)
        )
        #expect(accepted.statusCode == 200)
        #expect(accepted.data == Data("1234".utf8))
    }

    @Test("Profile store persists remote settings and computes due profiles")
    func persistsRemoteSettings() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "MClashSubscriptionTests-\(UUID().uuidString)",
            isDirectory: true
        )
        let layout = ProfileDirectoryLayout(rootDirectory: root)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let downloader = SubscriptionFeatureStubDownloader(
            response: SubscriptionDownloadResponse(
                statusCode: 200,
                data: Data("mixed-port: 7890\n".utf8),
                suggestedUpdateIntervalHours: 12,
                usage: SubscriptionUsage(total: 1_024),
                webPageURL: URL(string: "https://example.com/account")
            )
        )
        let store = try ProfileStore(layout: layout, downloader: downloader, now: { now })
        let originalURL = try #require(URL(string: "https://example.com/profile.yaml"))
        let profile = try await store.createRemoteProfile(
            name: "Remote",
            subscriptionURL: originalURL
        )

        let updated = try await store.updateRemoteProfileSettings(
            profile.id,
            name: "Renamed",
            subscriptionURL: originalURL,
            automaticUpdatesEnabled: true,
            updateIntervalHours: 6
        )
        guard case let .remote(remote) = updated.origin else {
            Issue.record("Expected remote metadata")
            return
        }
        #expect(updated.name == "Renamed")
        #expect(remote.updateIntervalHours == 6)
        #expect(remote.providerSuggestedUpdateIntervalHours == 12)
        #expect(
            try await store.remoteProfileIDsDueForAutomaticUpdate(
                at: now.addingTimeInterval(6 * 3_600)
            ) == [profile.id]
        )
    }
}

private final class BoundedDownloadURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "example.test"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }

        let headers: [String: String]
        let chunks: [Data]
        switch url.path {
        case "/declared-too-large":
            headers = ["Content-Length": "100"]
            chunks = [Data("x".utf8)]
        case "/streamed-too-large":
            headers = [:]
            chunks = [Data("123".utf8), Data("45".utf8)]
        default:
            headers = ["Content-Length": "4"]
            chunks = [Data("12".utf8), Data("34".utf8)]
        }
        guard let response = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: headers
        ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }

        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        for chunk in chunks {
            client?.urlProtocol(self, didLoad: chunk)
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private actor SubscriptionFeatureStubDownloader: SubscriptionDownloading {
    let response: SubscriptionDownloadResponse

    init(response: SubscriptionDownloadResponse) {
        self.response = response
    }

    func download(_ request: URLRequest) async throws -> SubscriptionDownloadResponse {
        response
    }
}
