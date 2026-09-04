import Foundation

public struct ProfileDirectoryLayout: Equatable, Sendable {
    public let rootDirectory: URL

    public init(rootDirectory: URL) {
        self.rootDirectory = rootDirectory.standardizedFileURL
    }

    public static func applicationSupport(
        applicationIdentifier: String? = nil,
        fileManager: FileManager = .default
    ) throws -> ProfileDirectoryLayout {
        // The environment override is intentionally opt-in.  Production
        // launches have no such variable and therefore retain the historical
        // `MClash` directory.  This gives development builds a private store
        // without changing the app's bundle identifier or live state.
        let applicationIdentifier = resolvedApplicationIdentifier(
            explicit: applicationIdentifier,
            environment: ProcessInfo.processInfo.environment
        )
        guard
            !applicationIdentifier.isEmpty,
            applicationIdentifier != ".",
            applicationIdentifier != "..",
            !applicationIdentifier.contains("/"),
            !applicationIdentifier.contains(":")
        else {
            throw ProfileDirectoryLayoutError.invalidApplicationIdentifier
        }

        let applicationSupport = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return ProfileDirectoryLayout(
            rootDirectory: applicationSupport.appendingPathComponent(
                applicationIdentifier,
                isDirectory: true
            )
        )
    }

    static func resolvedApplicationIdentifier(
        explicit: String?,
        environment: [String: String]
    ) -> String {
        explicit
            ?? environment["MCLASH_APPLICATION_SUPPORT_IDENTIFIER"]
            ?? (CommandLine.arguments.contains("--mclash-test-instance")
                ? "MClash-Shadow"
                : nil)
            ?? "MClash"
    }

    public var profilesDirectory: URL {
        rootDirectory.appendingPathComponent("Profiles", isDirectory: true)
    }

    public func profileDirectory(for id: ProfileID) -> URL {
        profilesDirectory.appendingPathComponent(id.description, isDirectory: true)
    }

    public func configurationURL(for id: ProfileID) -> URL {
        profileDirectory(for: id).appendingPathComponent("config.yaml", isDirectory: false)
    }

    public func metadataURL(for id: ProfileID) -> URL {
        profileDirectory(for: id).appendingPathComponent("metadata.json", isDirectory: false)
    }

    public var stateDirectory: URL {
        rootDirectory.appendingPathComponent("State", isDirectory: true)
    }

    /// Authoritative MClash configuration storage. Imported profile files
    /// remain under `Profiles` as read-only migration/audit snapshots; these
    /// directories contain the strategy-owned model used to generate runtime
    /// configuration.
    public var configurationDirectory: URL {
        rootDirectory.appendingPathComponent("Configuration", isDirectory: true)
    }

    public var sourcesDirectory: URL {
        configurationDirectory.appendingPathComponent("Sources", isDirectory: true)
    }

    public var nodeCatalogDirectory: URL {
        configurationDirectory.appendingPathComponent("Nodes", isDirectory: true)
    }

    public var workspacesDirectory: URL {
        configurationDirectory.appendingPathComponent("Workspaces", isDirectory: true)
    }

    public var snapshotsDirectory: URL {
        configurationDirectory.appendingPathComponent("Snapshots", isDirectory: true)
    }

    /// MClash-owned local caches for explicitly added remote rule sets. These
    /// files are derived data, never imported Profile policy, and can be
    /// replaced atomically by the native rule-set refresher.
    public var ruleSetsDirectory: URL {
        configurationDirectory.appendingPathComponent("RuleSets", isDirectory: true)
    }

    public var configurationManifestURL: URL {
        configurationDirectory.appendingPathComponent("manifest.json", isDirectory: false)
    }

    public var configurationStagingDirectory: URL {
        configurationDirectory.appendingPathComponent("Staging", isDirectory: true)
    }

    public var activeProfileStateURL: URL {
        stateDirectory.appendingPathComponent("active-profile.json", isDirectory: false)
    }

    public var runtimeDirectory: URL {
        rootDirectory.appendingPathComponent("Runtime", isDirectory: true)
    }

    public var runtimeConfigurationURL: URL {
        runtimeDirectory.appendingPathComponent("config.yaml", isDirectory: false)
    }

    public var runtimeStagingDirectory: URL {
        runtimeDirectory.appendingPathComponent("Staging", isDirectory: true)
    }

    /// Private, local-only operational history. This directory must never be
    /// included in profile exports or backups.
    public var trafficHistoryDirectory: URL {
        rootDirectory.appendingPathComponent("TrafficHistory", isDirectory: true)
    }

    public var trafficHistoryDatabaseURL: URL {
        trafficHistoryDirectory.appendingPathComponent("traffic-history.sqlite3", isDirectory: false)
    }

    public func createDirectories(fileManager: FileManager = .default) throws {
        for directory in [
            rootDirectory,
            profilesDirectory,
            stateDirectory,
            configurationDirectory,
            sourcesDirectory,
            nodeCatalogDirectory,
            workspacesDirectory,
            snapshotsDirectory,
            ruleSetsDirectory,
            configurationStagingDirectory,
            runtimeDirectory,
            runtimeStagingDirectory,
            trafficHistoryDirectory,
        ] {
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try fileManager.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: directory.path
            )
        }
    }
}

public enum ProfileDirectoryLayoutError: Error, Equatable, Sendable {
    case invalidApplicationIdentifier
}

extension ProfileDirectoryLayoutError: LocalizedError {
    public var errorDescription: String? {
        AppLocalization.string("The profile storage identifier is invalid.")
    }
}
