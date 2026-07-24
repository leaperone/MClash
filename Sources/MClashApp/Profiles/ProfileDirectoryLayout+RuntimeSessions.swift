import Foundation

public extension ProfileDirectoryLayout {
    /// Versioned desired state for all profile core sessions.
    var profileRuntimePlanURL: URL {
        stateDirectory.appendingPathComponent(
            "profile-runtime-plan.json",
            isDirectory: false
        )
    }

    /// Private staging area used only for atomic runtime-plan replacement.
    var profileRuntimePlanStagingDirectory: URL {
        stateDirectory.appendingPathComponent(
            "ProfileRuntimePlanStaging",
            isDirectory: true
        )
    }

    /// The root containing one isolated runtime configuration per profile.
    func runtimeSessionDirectory(for id: ProfileID) -> URL {
        runtimeDirectory.appendingPathComponent(
            id.description,
            isDirectory: true
        )
    }

    func runtimeConfigurationURL(for id: ProfileID) -> URL {
        runtimeSessionDirectory(for: id).appendingPathComponent(
            "config.yaml",
            isDirectory: false
        )
    }

    func runtimeStagingDirectory(for id: ProfileID) -> URL {
        runtimeSessionDirectory(for: id).appendingPathComponent(
            "Staging",
            isDirectory: true
        )
    }

    var coreHomesDirectory: URL {
        rootDirectory.appendingPathComponent("CoreHome", isDirectory: true)
    }

    func coreHomeDirectory(for id: ProfileID) -> URL {
        coreHomesDirectory.appendingPathComponent(
            id.description,
            isDirectory: true
        )
    }

    /// Creates only the private directories needed by one profile session.
    func createRuntimeDirectories(
        for id: ProfileID,
        fileManager: FileManager = .default
    ) throws {
        for directory in [
            rootDirectory,
            runtimeDirectory,
            runtimeSessionDirectory(for: id),
            runtimeStagingDirectory(for: id),
            coreHomesDirectory,
            coreHomeDirectory(for: id),
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
