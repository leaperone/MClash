import Foundation

public actor ProfileStore {
    public let layout: ProfileDirectoryLayout

    private let fileManager = FileManager.default
    private let downloader: any SubscriptionDownloading
    private let replacer: AtomicFileReplacer
    private let now: @Sendable () -> Date
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(
        layout: ProfileDirectoryLayout,
        downloader: any SubscriptionDownloading = URLSessionSubscriptionDownloader(),
        replacer: AtomicFileReplacer = AtomicFileReplacer(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) throws {
        self.layout = layout
        self.downloader = downloader
        self.replacer = replacer
        self.now = now

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder

        try layout.createDirectories(fileManager: fileManager)
    }

    @discardableResult
    public func createLocalProfile(name: String, yaml: Data) throws -> ProfileMetadata {
        try createProfile(name: name, yaml: yaml, origin: .local)
    }

    @discardableResult
    public func importProfile(from sourceURL: URL, name: String? = nil) throws -> ProfileMetadata {
        var isDirectory: ObjCBool = false
        guard
            fileManager.fileExists(atPath: sourceURL.path, isDirectory: &isDirectory),
            !isDirectory.boolValue
        else {
            throw ProfileStoreError.importSourceMissing
        }
        let pathExtension = sourceURL.pathExtension.lowercased()
        guard pathExtension == "yaml" || pathExtension == "yml" else {
            throw ProfileStoreError.unsupportedFileExtension
        }

        let data = try Data(contentsOf: sourceURL, options: .mappedIfSafe)
        let fallbackName = sourceURL.deletingPathExtension().lastPathComponent
        return try createProfile(
            name: name ?? fallbackName,
            yaml: data,
            origin: .imported(originalFileName: sourceURL.lastPathComponent)
        )
    }

    @discardableResult
    public func createRemoteProfile(
        name: String,
        subscriptionURL: URL,
        validator: any ProfileValidating = AcceptingProfileValidator()
    ) async throws -> ProfileMetadata {
        try validateRemoteURL(subscriptionURL)
        let checkedAt = now()
        let response = try await downloader.download(URLRequest(url: subscriptionURL))
        guard (200..<300).contains(response.statusCode) else {
            throw ProfileStoreError.unexpectedHTTPStatus(response.statusCode)
        }
        guard let data = response.data, !data.isEmpty else {
            throw ProfileStoreError.emptyConfiguration
        }

        let staged = try await replacer.stage(
            data: data,
            in: layout.runtimeStagingDirectory,
            preferredName: "subscription.yaml"
        )
        do {
            try await validator.validate(configurationAt: staged)
            try? fileManager.removeItem(at: staged)
        } catch {
            try? fileManager.removeItem(at: staged)
            throw error
        }

        let remote = RemoteSubscriptionMetadata(
            url: subscriptionURL,
            eTag: response.eTag,
            lastModified: response.lastModified,
            lastCheckedAt: checkedAt,
            lastSuccessfulUpdateAt: checkedAt
        )
        return try createProfile(name: name, yaml: data, origin: .remote(remote))
    }

    public func profiles() throws -> [ProfileMetadata] {
        let profileDirectories = try fileManager.contentsOfDirectory(
            at: layout.profilesDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )

        var result: [ProfileMetadata] = []
        for directory in profileDirectories {
            let values = try directory.resourceValues(forKeys: [.isDirectoryKey])
            guard values.isDirectory == true else { continue }
            let metadataURL = directory.appendingPathComponent("metadata.json", isDirectory: false)
            guard fileManager.fileExists(atPath: metadataURL.path) else { continue }
            result.append(try decode(ProfileMetadata.self, from: metadataURL))
        }
        return result.sorted {
            if $0.createdAt == $1.createdAt {
                return $0.id.description < $1.id.description
            }
            return $0.createdAt < $1.createdAt
        }
    }

    public func metadata(for id: ProfileID) throws -> ProfileMetadata {
        let url = layout.metadataURL(for: id)
        guard fileManager.fileExists(atPath: url.path) else {
            throw ProfileStoreError.profileNotFound(id)
        }
        return try decode(ProfileMetadata.self, from: url)
    }

    public func configurationData(for id: ProfileID) throws -> Data {
        let url = layout.configurationURL(for: id)
        guard fileManager.fileExists(atPath: url.path) else {
            throw ProfileStoreError.profileNotFound(id)
        }
        return try Data(contentsOf: url, options: .mappedIfSafe)
    }

    public func activeProfileID() throws -> ProfileID? {
        guard fileManager.fileExists(atPath: layout.activeProfileStateURL.path) else {
            return nil
        }
        return try decode(ActiveProfileState.self, from: layout.activeProfileStateURL).profileID
    }

    public func setActiveProfile(_ id: ProfileID?) async throws {
        if let id {
            _ = try metadata(for: id)
        }
        let receipt = try await replaceEncoded(
            ActiveProfileState(profileID: id),
            at: layout.activeProfileStateURL,
            preferredName: "active-profile.json"
        )
        try await replacer.commit(receipt)
    }

    public func stageRuntimeConfiguration(for id: ProfileID) async throws -> URL {
        let data = try configurationData(for: id)
        return try await replacer.stage(
            data: data,
            in: layout.runtimeStagingDirectory,
            preferredName: "config.yaml"
        )
    }

    public func replaceRuntimeConfiguration(
        withStagedFile stagedURL: URL
    ) async throws -> FileReplacementReceipt {
        try await replacer.replace(
            destinationURL: layout.runtimeConfigurationURL,
            withStagedFile: stagedURL
        )
    }

    public func commitReplacement(_ receipt: FileReplacementReceipt) async throws {
        try await replacer.commit(receipt)
    }

    public func rollbackReplacement(_ receipt: FileReplacementReceipt) async throws {
        try await replacer.rollback(receipt)
    }

    @discardableResult
    public func activateProfile(
        _ id: ProfileID,
        validator: any ProfileValidating
    ) async throws -> RuntimeConfigurationActivation {
        let previousProfileID = try activeProfileID()
        let stagedRuntime = try await stageRuntimeConfiguration(for: id)

        do {
            try await validator.validate(configurationAt: stagedRuntime)
        } catch {
            try? fileManager.removeItem(at: stagedRuntime)
            throw error
        }

        let runtimeReceipt = try await replaceRuntimeConfiguration(withStagedFile: stagedRuntime)
        do {
            let stateReceipt = try await replaceEncoded(
                ActiveProfileState(profileID: id),
                at: layout.activeProfileStateURL,
                preferredName: "active-profile.json"
            )
            try await replacer.commit(stateReceipt)
            try await replacer.commit(runtimeReceipt)
        } catch {
            try? await replacer.rollback(runtimeReceipt)
            throw error
        }

        return RuntimeConfigurationActivation(
            profileID: id,
            previousProfileID: previousProfileID,
            configurationURL: layout.runtimeConfigurationURL
        )
    }

    @discardableResult
    public func refreshRemoteProfile(
        _ id: ProfileID,
        validator: any ProfileValidating = AcceptingProfileValidator()
    ) async throws -> RemoteProfileRefreshResult {
        var profile = try metadata(for: id)
        guard case var .remote(remote) = profile.origin else {
            throw ProfileStoreError.profileIsNotRemote(id)
        }

        var request = URLRequest(url: remote.url)
        if let eTag = remote.eTag {
            request.setValue(eTag, forHTTPHeaderField: "If-None-Match")
        }
        if let lastModified = remote.lastModified {
            request.setValue(lastModified, forHTTPHeaderField: "If-Modified-Since")
        }

        let response = try await downloader.download(request)
        let checkedAt = now()
        remote.lastCheckedAt = checkedAt

        if response.statusCode == 304 {
            remote.eTag = response.eTag ?? remote.eTag
            remote.lastModified = response.lastModified ?? remote.lastModified
            profile.origin = .remote(remote)
            let metadataReceipt = try await replaceEncoded(
                profile,
                at: layout.metadataURL(for: id),
                preferredName: "metadata.json"
            )
            try await replacer.commit(metadataReceipt)
            return .notModified(profile)
        }

        guard (200..<300).contains(response.statusCode) else {
            throw ProfileStoreError.unexpectedHTTPStatus(response.statusCode)
        }
        guard let data = response.data, !data.isEmpty else {
            throw ProfileStoreError.emptyConfiguration
        }

        let stagedConfiguration = try await replacer.stage(
            data: data,
            in: layout.runtimeStagingDirectory,
            preferredName: "subscription.yaml"
        )
        do {
            try await validator.validate(configurationAt: stagedConfiguration)
        } catch {
            try? fileManager.removeItem(at: stagedConfiguration)
            throw error
        }

        let configurationReceipt = try await replacer.replace(
            destinationURL: layout.configurationURL(for: id),
            withStagedFile: stagedConfiguration
        )
        do {
            remote.eTag = response.eTag
            remote.lastModified = response.lastModified
            remote.lastSuccessfulUpdateAt = checkedAt
            profile.origin = .remote(remote)
            profile.updatedAt = checkedAt

            let metadataReceipt = try await replaceEncoded(
                profile,
                at: layout.metadataURL(for: id),
                preferredName: "metadata.json"
            )
            try await replacer.commit(metadataReceipt)
            try await replacer.commit(configurationReceipt)
            return .updated(profile)
        } catch {
            try? await replacer.rollback(configurationReceipt)
            throw error
        }
    }

    public func removeProfile(_ id: ProfileID) throws {
        let directory = layout.profileDirectory(for: id)
        guard fileManager.fileExists(atPath: directory.path) else {
            throw ProfileStoreError.profileNotFound(id)
        }
        if try activeProfileID() == id {
            throw ProfileStoreError.cannotRemoveActiveProfile(id)
        }
        try fileManager.removeItem(at: directory)
    }

    /// Restores a previously captured profile configuration and metadata.
    /// Used when a refreshed active subscription validates but cannot start.
    public func restoreProfile(
        metadata: ProfileMetadata,
        configurationData: Data
    ) async throws {
        guard !configurationData.isEmpty else {
            throw ProfileStoreError.emptyConfiguration
        }
        _ = try self.metadata(for: metadata.id)

        let stagedConfiguration = try await replacer.stage(
            data: configurationData,
            in: layout.runtimeStagingDirectory,
            preferredName: "profile-rollback.yaml"
        )
        let configurationReceipt = try await replacer.replace(
            destinationURL: layout.configurationURL(for: metadata.id),
            withStagedFile: stagedConfiguration
        )

        do {
            let metadataReceipt = try await replaceEncoded(
                metadata,
                at: layout.metadataURL(for: metadata.id),
                preferredName: "metadata-rollback.json"
            )
            try await replacer.commit(metadataReceipt)
            try await replacer.commit(configurationReceipt)
        } catch {
            try? await replacer.rollback(configurationReceipt)
            throw error
        }
    }

    private func createProfile(
        name: String,
        yaml: Data,
        origin: ProfileOrigin
    ) throws -> ProfileMetadata {
        guard !yaml.isEmpty else {
            throw ProfileStoreError.emptyConfiguration
        }
        let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedName.isEmpty else {
            throw ProfileStoreError.emptyProfileName
        }

        let id = ProfileID()
        let timestamp = now()
        let metadata = ProfileMetadata(
            id: id,
            name: normalizedName,
            origin: origin,
            createdAt: timestamp,
            updatedAt: timestamp
        )
        let directory = layout.profileDirectory(for: id)

        do {
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
            let configurationURL = layout.configurationURL(for: id)
            try yaml.write(to: configurationURL, options: .withoutOverwriting)
            try fileManager.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: configurationURL.path
            )
            try encode(metadata).write(
                to: layout.metadataURL(for: id),
                options: .withoutOverwriting
            )
            try fileManager.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: layout.metadataURL(for: id).path
            )
            return metadata
        } catch {
            try? fileManager.removeItem(at: directory)
            throw error
        }
    }

    private func validateRemoteURL(_ url: URL) throws {
        guard let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http" else {
            throw ProfileStoreError.invalidSubscriptionURL
        }
    }

    private func encode<T: Encodable>(_ value: T) throws -> Data {
        try encoder.encode(value)
    }

    private func decode<T: Decodable>(_ type: T.Type, from url: URL) throws -> T {
        try decoder.decode(type, from: Data(contentsOf: url))
    }

    private func replaceEncoded<T: Encodable>(
        _ value: T,
        at destinationURL: URL,
        preferredName: String
    ) async throws -> FileReplacementReceipt {
        let staged = try await replacer.stage(
            data: encode(value),
            in: layout.runtimeStagingDirectory,
            preferredName: preferredName
        )
        do {
            return try await replacer.replace(
                destinationURL: destinationURL,
                withStagedFile: staged
            )
        } catch {
            try? fileManager.removeItem(at: staged)
            throw error
        }
    }
}

public enum ProfileStoreError: Error, Equatable, Sendable {
    case profileNotFound(ProfileID)
    case profileIsNotRemote(ProfileID)
    case cannotRemoveActiveProfile(ProfileID)
    case importSourceMissing
    case unsupportedFileExtension
    case invalidSubscriptionURL
    case unexpectedHTTPStatus(Int)
    case emptyConfiguration
    case emptyProfileName
}

extension ProfileStoreError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case let .profileNotFound(id):
            "Profile \(id.description) was not found."
        case let .profileIsNotRemote(id):
            "Profile \(id.description) is not a remote subscription."
        case let .cannotRemoveActiveProfile(id):
            "Profile \(id.description) is active and cannot be removed."
        case .importSourceMissing:
            "The selected profile file does not exist."
        case .unsupportedFileExtension:
            "MClash can import .yaml and .yml profile files."
        case .invalidSubscriptionURL:
            "The subscription URL must use HTTP or HTTPS."
        case let .unexpectedHTTPStatus(status):
            "The subscription server returned HTTP \(status)."
        case .emptyConfiguration:
            "The profile configuration is empty."
        case .emptyProfileName:
            "Enter a name for the profile."
        }
    }
}
