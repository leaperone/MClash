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
    }
}

private struct Fixture {
    let root: URL
    let layout: ProfileDirectoryLayout
    let store: ProfileStore

    init(downloader: any SubscriptionDownloading = StubDownloader(responses: [])) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "MClashTests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        layout = ProfileDirectoryLayout(rootDirectory: root.appendingPathComponent("Application Support"))
        store = try ProfileStore(
            layout: layout,
            downloader: downloader,
            now: { Date(timeIntervalSince1970: 1_789_000_000) }
        )
    }
}

private actor StubDownloader: SubscriptionDownloading {
    private var queuedResponses: [SubscriptionDownloadResponse]
    private(set) var requests: [URLRequest] = []

    init(responses: [SubscriptionDownloadResponse]) {
        self.queuedResponses = responses
    }

    func download(_ request: URLRequest) async throws -> SubscriptionDownloadResponse {
        requests.append(request)
        guard !queuedResponses.isEmpty else {
            throw StubDownloaderError.noResponse
        }
        return queuedResponses.removeFirst()
    }
}

private enum StubDownloaderError: Error {
    case noResponse
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
