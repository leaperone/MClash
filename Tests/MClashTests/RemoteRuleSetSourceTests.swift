import Foundation
import Testing
@testable import MClashApp

@Suite("Remote rule set sources")
struct RemoteRuleSetSourceTests {
    @Test("Refresh parses YAML payload and stores a last-good cache")
    func refreshesYAML() async throws {
        let fixture = try Fixture(response: .init(statusCode: 200, data: Data("payload:\n  - DOMAIN,example.com\n  - DOMAIN-SUFFIX,internal.example\n".utf8), eTag: "v1"))
        let source = RemoteRuleSetSource(cacheDirectory: fixture.cache, downloader: fixture.downloader)
        let result = try await source.refresh(fixture.ruleSet(behavior: .classical, format: .yaml))
        #expect(result.state == .updated)
        #expect(result.ruleSet.rules == ["DOMAIN,example.com", "DOMAIN-SUFFIX,internal.example"])
        let cached = try await source.loadCached(fixture.ruleSet(behavior: .classical, format: .yaml))
        #expect(cached.rules == result.ruleSet.rules)
        await fixture.downloader.setResponse(.init(statusCode: 200, data: Data("payload:\n  - good.example\nmetadata:\n  - must-not-be-read\n".utf8)))
        await #expect(throws: RemoteRuleSetError.invalidYAML) {
            try await source.refresh(fixture.ruleSet(behavior: .classical, format: .yaml))
        }
        let afterMalformed = try await source.loadCached(fixture.ruleSet(behavior: .classical, format: .yaml))
        #expect(afterMalformed.rules == cached.rules)
    }

    @Test("Refresh sends validators and uses a 304 last-good cache")
    func handlesNotModified() async throws {
        let fixture = try Fixture(response: .init(statusCode: 200, data: Data("example.com\n".utf8), eTag: "v1"))
        let source = RemoteRuleSetSource(cacheDirectory: fixture.cache, downloader: fixture.downloader)
        let first = try await source.refresh(fixture.ruleSet(behavior: .domain, format: .text))
        await fixture.downloader.setResponse(.init(statusCode: 304, data: nil, eTag: "v1"))
        let second = try await source.refresh(fixture.ruleSet(behavior: .domain, format: .text))
        #expect(first.ruleSet.rules == second.ruleSet.rules)
        #expect(second.state == .notModified)
        let request = await fixture.downloader.lastRequest
        #expect(request?.value(forHTTPHeaderField: "If-None-Match") == "v1")
    }

    @Test("Invalid payload and offline response preserve last-good cache")
    func preservesLastGood() async throws {
        let fixture = try Fixture(response: .init(statusCode: 200, data: Data("1.1.1.0/24\n".utf8)))
        let source = RemoteRuleSetSource(cacheDirectory: fixture.cache, downloader: fixture.downloader)
        let ruleSet = fixture.ruleSet(behavior: .ipcidr, format: .text)
        _ = try await source.refresh(ruleSet)
        await fixture.downloader.setResponse(.init(statusCode: 200, data: Data("\n# empty\n".utf8)))
        await #expect(throws: RemoteRuleSetError.emptyPayload) { try await source.refresh(ruleSet) }
        let cachedAfterInvalid = try await source.loadCached(ruleSet)
        #expect(cachedAfterInvalid.rules == ["1.1.1.0/24"])
        await fixture.downloader.setError(TestDownloaderError.offline)
        await #expect(throws: RemoteRuleSetError.downloadFailed) { try await source.refresh(ruleSet) }
        let cachedAfterOffline = try await source.loadCached(ruleSet)
        #expect(cachedAfterOffline.rules == ["1.1.1.0/24"])
    }

    @Test("Invalid CIDR and embedded classical actions cannot replace a valid cache")
    func rejectsSemanticInjection() async throws {
        let fixture = try Fixture(response: .init(statusCode: 200, data: Data("DOMAIN,good.example\n".utf8)))
        let source = RemoteRuleSetSource(cacheDirectory: fixture.cache, downloader: fixture.downloader)
        let ruleSet = fixture.ruleSet(behavior: .classical, format: .text)
        _ = try await source.refresh(ruleSet)
        await fixture.downloader.setResponse(.init(statusCode: 200, data: Data("DOMAIN,bad.example,REJECT\n".utf8)))
        await #expect(throws: RemoteRuleSetError.invalidRulePayload) { try await source.refresh(ruleSet) }
        let cached = try await source.loadCached(ruleSet)
        #expect(cached.rules == ["DOMAIN,good.example"])

        var cidr = fixture.ruleSet(behavior: .ipcidr, format: .text)
        cidr.sourceURL = URL(string: "https://rules.example/cidr")
        await fixture.downloader.setResponse(.init(statusCode: 200, data: Data("not-a-cidr\n".utf8)))
        await #expect(throws: RemoteRuleSetError.invalidRulePayload) { try await source.refresh(cidr) }
    }

    @Test("Optional runtime validation runs before cache commit")
    func validatesBeforeCommit() async throws {
        let fixture = try Fixture(response: .init(statusCode: 200, data: Data("example.com\n".utf8)))
        let source = RemoteRuleSetSource(cacheDirectory: fixture.cache, downloader: fixture.downloader)
        let ruleSet = fixture.ruleSet(behavior: .domain, format: .text)
        _ = try await source.refresh(ruleSet)
        await fixture.downloader.setResponse(.init(statusCode: 200, data: Data("new.example\n".utf8)))
        await #expect(throws: RemoteRuleSetError.validationFailed) {
            try await source.refresh(ruleSet, validate: { _ in throw TestDownloaderError.offline })
        }
        let cached = try await source.loadCached(ruleSet)
        #expect(cached.rules == ["example.com"])
    }

    @Test("Changed source URL cannot reuse the old cache")
    func rejectsChangedSource() async throws {
        let fixture = try Fixture(response: .init(statusCode: 200, data: Data("example.com\n".utf8)))
        let source = RemoteRuleSetSource(cacheDirectory: fixture.cache, downloader: fixture.downloader)
        let original = fixture.ruleSet(behavior: .domain, format: .text)
        _ = try await source.refresh(original)
        let changedBehavior = fixture.ruleSet(behavior: .classical, format: .text)
        await #expect(throws: RemoteRuleSetError.cacheSourceMismatch) {
            try await source.loadCached(changedBehavior)
        }
        var changed = original
        changed.sourceURL = URL(string: "https://other.example/rules.txt")
        await #expect(throws: RemoteRuleSetError.cacheSourceMismatch) { try await source.loadCached(changed) }
        let refreshed = try await source.refresh(changed)
        #expect(refreshed.ruleSet.rules == ["example.com"])
    }

    @Test("MRS and credential URLs are rejected before download")
    func rejectsUnsafeSources() async throws {
        let fixture = try Fixture(response: .init(statusCode: 200, data: Data("example.com\n".utf8)))
        let source = RemoteRuleSetSource(cacheDirectory: fixture.cache, downloader: fixture.downloader)
        await #expect(throws: RemoteRuleSetError.unsupportedFormat) {
            try await source.refresh(fixture.ruleSet(behavior: .domain, format: .mrs))
        }
        var credentials = fixture.ruleSet(behavior: .domain, format: .text)
        credentials.sourceURL = URL(string: "https://user:password@example.com/rules")
        await #expect(throws: RemoteRuleSetError.sourceCredentialsNotAllowed) { try await source.refresh(credentials) }
        #expect(await fixture.downloader.requestCount == 0)
    }

    private struct Fixture {
        let cache: URL
        let downloader: TestDownloader
        let url: URL
        let id: RuleSetID

        init(response: SubscriptionDownloadResponse) throws {
            cache = FileManager.default.temporaryDirectory.appendingPathComponent("mclash-rule-set-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
            url = URL(string: "https://rules.example/list")!
            downloader = TestDownloader(response: response)
            id = RuleSetID()
        }

        func ruleSet(behavior: RuleSetBehavior, format: RuleSetFormat) -> RuleSet {
            RuleSet(id: id, name: "Fixture", sourceURL: url, behavior: behavior, format: format)
        }
    }
}

private enum TestDownloaderError: Error, Equatable, Sendable {
    case offline
}

private actor TestDownloader: SubscriptionDownloading {
    private var response: SubscriptionDownloadResponse?
    private var failure: Error?
    private(set) var requestCount = 0
    private(set) var lastRequest: URLRequest?

    init(response: SubscriptionDownloadResponse) {
        self.response = response
    }

    func setResponse(_ response: SubscriptionDownloadResponse) {
        self.response = response
        self.failure = nil
    }

    func setError(_ error: Error) {
        self.response = nil
        self.failure = error
    }

    func download(_ request: URLRequest) async throws -> SubscriptionDownloadResponse {
        requestCount += 1
        lastRequest = request
        if let failure { throw failure }
        return response!
    }
}
