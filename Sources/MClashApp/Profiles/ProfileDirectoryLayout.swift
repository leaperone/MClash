import Foundation

public struct ProfileDirectoryLayout: Equatable, Sendable {
    public let rootDirectory: URL

    public init(rootDirectory: URL) {
        self.rootDirectory = rootDirectory.standardizedFileURL
    }

    public static func applicationSupport(
        applicationIdentifier: String = "MClash",
        fileManager: FileManager = .default
    ) throws -> ProfileDirectoryLayout {
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

    public func createDirectories(fileManager: FileManager = .default) throws {
        for directory in [
            rootDirectory,
            profilesDirectory,
            stateDirectory,
            runtimeDirectory,
            runtimeStagingDirectory,
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
        "The profile storage identifier is invalid."
    }
}
