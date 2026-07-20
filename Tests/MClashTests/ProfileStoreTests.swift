import Foundation
import Testing
@testable import MClashApp

@Suite("Profile Store")
struct ProfileStoreTests {
    @Test("Layout creates a private Application Support hierarchy")
    func layoutCreatesPrivateApplicationSupportHierarchy() async throws {
        let fixture = try Fixture()

        for directory in [
            fixture.layout.profilesDirectory,
            fixture.layout.stateDirectory,
            fixture.layout.runtimeDirectory,
            fixture.layout.runtimeStagingDirectory,
            fixture.layout.trafficHistoryDirectory,
        ] {
            var isDirectory: ObjCBool = false
            #expect(
                FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory)
            )
            #expect(isDirectory.boolValue)
        }

        #expect(fixture.layout.runtimeConfigurationURL.lastPathComponent == "config.yaml")
    }

    @Test("Local and imported profiles preserve opaque YAML")
    func localAndImportedProfilesPreserveOpaqueYAML() async throws {
        let fixture = try Fixture()
        let yaml = Data("mixed-port: 7890\n# keep this comment\n".utf8)
        let local = try await fixture.store.createLocalProfile(name: "Local", yaml: yaml)

        let importedURL = fixture.root.appendingPathComponent("Imported.yml")
        let importedYAML = Data("proxies:\n  - { name: test, type: direct }\n".utf8)
        try importedYAML.write(to: importedURL)
        let imported = try await fixture.store.importProfile(from: importedURL)

        let storedLocalYAML = try await fixture.store.configurationData(for: local.id)
        let storedImportedYAML = try await fixture.store.configurationData(for: imported.id)
        let profiles = try await fixture.store.profiles()
        #expect(storedLocalYAML == yaml)
        #expect(storedImportedYAML == importedYAML)
        #expect(imported.name == "Imported")
        #expect(imported.origin == .imported(originalFileName: "Imported.yml"))
        #expect(profiles.count == 2)
    }

    @Test("Activation persists state and validation failure keeps the previous runtime")
    func activationPersistsStateAndValidationFailureKeepsPreviousRuntime() async throws {
        let fixture = try Fixture()
        let firstYAML = Data("mixed-port: 7890\n".utf8)
        let secondYAML = Data("mixed-port: 7891\n".utf8)
        let first = try await fixture.store.createLocalProfile(name: "First", yaml: firstYAML)
        let second = try await fixture.store.createLocalProfile(name: "Second", yaml: secondYAML)

        let firstActivation = try await fixture.store.activateProfile(
            first.id,
            validator: RecordingValidator()
        )
        let firstRuntimeYAML = try Data(contentsOf: fixture.layout.runtimeConfigurationURL)
        let firstActiveProfileID = try await fixture.store.activeProfileID()
        #expect(firstActivation.previousProfileID == nil)
        #expect(firstRuntimeYAML == firstYAML)
        #expect(firstActiveProfileID == first.id)

        let reopenedStore = try ProfileStore(layout: fixture.layout)
        let persistedActiveProfileID = try await reopenedStore.activeProfileID()
        #expect(persistedActiveProfileID == first.id)

        do {
            _ = try await fixture.store.activateProfile(second.id, validator: RejectingValidator())
            Issue.record("Expected validation to fail")
        } catch is ValidationFailure {
            // Expected.
        }

        let runtimeYAMLAfterRejection = try Data(contentsOf: fixture.layout.runtimeConfigurationURL)
        let activeProfileAfterRejection = try await fixture.store.activeProfileID()
        #expect(runtimeYAMLAfterRejection == firstYAML)
        #expect(activeProfileAfterRejection == first.id)
    }

    @Test("Remote refresh uses conditional headers and handles not modified")
    func remoteRefreshUsesConditionalHeadersAndHandlesNotModified() async throws {
        let downloader = StubDownloader(responses: [
            SubscriptionDownloadResponse(
                statusCode: 200,
                data: Data("mixed-port: 7890\n".utf8),
                eTag: "\"one\"",
                lastModified: "Wed, 15 Jul 2026 10:00:00 GMT"
            ),
            SubscriptionDownloadResponse(statusCode: 304, data: nil),
        ])
        let fixture = try Fixture(downloader: downloader)
        let subscriptionURL = try #require(URL(string: "https://example.com/profile.yaml"))
        let profile = try await fixture.store.createRemoteProfile(
            name: "Remote",
            subscriptionURL: subscriptionURL,
            validator: RecordingValidator()
        )

        let result = try await fixture.store.refreshRemoteProfile(
            profile.id,
            validator: RecordingValidator()
        )
        guard case let .notModified(updatedMetadata) = result else {
            Issue.record("Expected notModified")
            return
        }
        guard case let .remote(remote) = updatedMetadata.origin else {
            Issue.record("Expected remote metadata")
            return
        }
        #expect(remote.eTag == "\"one\"")

        let requests = await downloader.requests
        try #require(requests.count == 2)
        #expect(requests[0].value(forHTTPHeaderField: "If-None-Match") == nil)
        #expect(requests[1].value(forHTTPHeaderField: "If-None-Match") == "\"one\"")
        #expect(
            requests[1].value(forHTTPHeaderField: "If-Modified-Since")
                == "Wed, 15 Jul 2026 10:00:00 GMT"
        )
    }

    @Test("Rejected remote refresh does not replace the stored configuration")
    func rejectedRemoteRefreshDoesNotReplaceStoredConfiguration() async throws {
        let original = Data("mixed-port: 7890\n".utf8)
        let downloader = StubDownloader(responses: [
            SubscriptionDownloadResponse(statusCode: 200, data: original, eTag: "old"),
            SubscriptionDownloadResponse(
                statusCode: 200,
                data: Data("this update is rejected\n".utf8),
                eTag: "new"
            ),
        ])
        let fixture = try Fixture(downloader: downloader)
        let url = try #require(URL(string: "https://example.com/profile.yaml"))
        let profile = try await fixture.store.createRemoteProfile(
            name: "Remote",
            subscriptionURL: url
        )

        do {
            _ = try await fixture.store.refreshRemoteProfile(
                profile.id,
                validator: RejectingValidator()
            )
            Issue.record("Expected validation failure")
        } catch is ValidationFailure {
            // Expected.
        }

        let storedConfiguration = try await fixture.store.configurationData(for: profile.id)
        let storedMetadata = try await fixture.store.metadata(for: profile.id)
        #expect(storedConfiguration == original)
        guard case let .remote(remote) = storedMetadata.origin else {
            Issue.record("Expected remote metadata")
            return
        }
        #expect(remote.eTag == "old")
        #expect(remote.lastFailureAt != nil)
        #expect(remote.consecutiveFailureCount == 1)
        #expect(remote.nextRetryAt != nil)
    }

    @Test("Refresh failure persists retry state and manual refresh ignores backoff")
    func refreshFailurePersistsRetryStateAndManualRefreshIgnoresBackoff() async throws {
        let initialDate = Date(timeIntervalSince1970: 1_789_000_000)
        let failureDate = initialDate.addingTimeInterval(60 * 60)
        let dateSource = TestDateSource(initialDate)
        let downloader = StubDownloader(steps: [
            .response(SubscriptionDownloadResponse(
                statusCode: 200,
                data: Data("mixed-port: 7890\n".utf8),
                eTag: "old"
            )),
            .failure(.noResponse),
            .response(SubscriptionDownloadResponse(statusCode: 304, data: nil)),
        ])
        let fixture = try Fixture(
            downloader: downloader,
            now: { dateSource.value },
            retryJitterFactor: { 1 }
        )
        let url = try #require(URL(string: "https://example.com/profile.yaml"))
        let profile = try await fixture.store.createRemoteProfile(
            name: "Remote",
            subscriptionURL: url
        )

        dateSource.value = failureDate
        await #expect(throws: StubDownloaderError.noResponse) {
            _ = try await fixture.store.refreshRemoteProfile(profile.id)
        }

        let failedProfile = try await fixture.store.metadata(for: profile.id)
        guard case let .remote(failedRemote) = failedProfile.origin else {
            Issue.record("Expected remote metadata")
            return
        }
        let retryAt = failureDate.addingTimeInterval(15 * 60)
        #expect(failedRemote.lastFailureAt == failureDate)
        #expect(failedRemote.consecutiveFailureCount == 1)
        #expect(failedRemote.nextRetryAt == retryAt)
        #expect(
            try await fixture.store.remoteProfileIDsDueForAutomaticUpdate(
                at: retryAt.addingTimeInterval(-1)
            ).isEmpty
        )
        #expect(
            try await fixture.store.remoteProfileIDsDueForAutomaticUpdate(at: retryAt)
                == [profile.id]
        )

        // The direct Store API is the manual refresh path. It must not reject
        // an attempt merely because the automatic retry deadline is pending.
        dateSource.value = failureDate.addingTimeInterval(60)
        let result = try await fixture.store.refreshRemoteProfile(profile.id)
        guard case let .notModified(recoveredProfile) = result,
              case let .remote(recoveredRemote) = recoveredProfile.origin else {
            Issue.record("Expected a successful not-modified refresh")
            return
        }
        #expect(recoveredRemote.lastFailureAt == nil)
        #expect(recoveredRemote.consecutiveFailureCount == 0)
        #expect(recoveredRemote.nextRetryAt == nil)
        let requestCount = await downloader.requests.count
        #expect(requestCount == 3)
    }

    @Test("Captured profile contents can be restored after a failed runtime rollout")
    func capturedProfileContentsCanBeRestored() async throws {
        let fixture = try Fixture()
        let originalYAML = Data("mixed-port: 7890\n".utf8)
        let profile = try await fixture.store.createLocalProfile(
            name: "Original",
            yaml: originalYAML
        )
        let originalMetadata = try await fixture.store.metadata(for: profile.id)

        let replacementMetadata = ProfileMetadata(
            id: profile.id,
            name: "Replacement",
            origin: profile.origin,
            createdAt: profile.createdAt,
            updatedAt: profile.updatedAt.addingTimeInterval(60)
        )
        try await fixture.store.restoreProfile(
            metadata: replacementMetadata,
            configurationData: Data("mixed-port: 7891\n".utf8)
        )
        try await fixture.store.restoreProfile(
            metadata: originalMetadata,
            configurationData: originalYAML
        )

        #expect(try await fixture.store.metadata(for: profile.id) == originalMetadata)
        #expect(try await fixture.store.configurationData(for: profile.id) == originalYAML)
    }
}

private struct Fixture {
    let root: URL
    let layout: ProfileDirectoryLayout
    let store: ProfileStore

    init(
        downloader: any SubscriptionDownloading = StubDownloader(responses: []),
        now: @escaping @Sendable () -> Date = {
            Date(timeIntervalSince1970: 1_789_000_000)
        },
        retryJitterFactor: @escaping @Sendable () -> Double = { 1 }
    ) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "MClashTests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        layout = ProfileDirectoryLayout(rootDirectory: root.appendingPathComponent("Application Support"))
        store = try ProfileStore(
            layout: layout,
            downloader: downloader,
            now: now,
            retryJitterFactor: retryJitterFactor
        )
    }
}

private actor StubDownloader: SubscriptionDownloading {
    private var steps: [StubDownloadStep]
    private(set) var requests: [URLRequest] = []

    init(responses: [SubscriptionDownloadResponse]) {
        steps = responses.map(StubDownloadStep.response)
    }

    init(steps: [StubDownloadStep]) {
        self.steps = steps
    }

    func download(_ request: URLRequest) async throws -> SubscriptionDownloadResponse {
        requests.append(request)
        guard !steps.isEmpty else {
            throw StubDownloaderError.noResponse
        }
        switch steps.removeFirst() {
        case let .response(response): return response
        case let .failure(error): throw error
        }
    }
}

private enum StubDownloadStep: Sendable {
    case response(SubscriptionDownloadResponse)
    case failure(StubDownloaderError)
}

private enum StubDownloaderError: Error, Equatable, Sendable {
    case noResponse
}

private final class TestDateSource: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue: Date

    init(_ value: Date) {
        storedValue = value
    }

    var value: Date {
        get { lock.withLock { storedValue } }
        set { lock.withLock { storedValue = newValue } }
    }
}

private actor RecordingValidator: ProfileValidating {
    private(set) var validatedData: [Data] = []

    func validate(configurationAt url: URL) async throws {
        validatedData.append(try Data(contentsOf: url))
    }
}

private struct RejectingValidator: ProfileValidating {
    func validate(configurationAt url: URL) async throws {
        throw ValidationFailure()
    }
}

private struct ValidationFailure: Error {}
