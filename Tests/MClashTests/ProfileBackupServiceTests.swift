import Foundation
import Testing
@testable import MClashApp

@Suite("Profile backup service")
struct ProfileBackupServiceTests {
    @Test("Export and restore round trip profiles, settings, and active state")
    func roundTrip() async throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(
            "MClashBackupTests-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: temporary) }
        let source = ProfileDirectoryLayout(
            rootDirectory: temporary.appendingPathComponent("Source", isDirectory: true)
        )
        let destination = ProfileDirectoryLayout(
            rootDirectory: temporary.appendingPathComponent("Destination", isDirectory: true)
        )
        let sourceStore = try ProfileStore(layout: source)
        let profileURL = temporary.appendingPathComponent("profile.yaml")
        try Data("mixed-port: 7890\n".utf8).write(to: profileURL)
        let profile = try await sourceStore.importProfile(from: profileURL)
        try await sourceStore.setActiveProfile(profile.id)
        let runtimePlan = ProfileRuntimePlan(
            sessions: [
                ProfileSessionSpec(
                    profileID: profile.id,
                    mixedPort: 18_900
                ),
            ],
            primaryProfileID: profile.id
        )
        try await ProfileRuntimePlanStore(layout: source).save(runtimePlan)
        let settings = source.rootDirectory.appendingPathComponent("Settings", isDirectory: true)
        try FileManager.default.createDirectory(at: settings, withIntermediateDirectories: true)
        try Data("settings".utf8).write(to: settings.appendingPathComponent("sample.txt"))

        let service = ProfileBackupService()
        let backup = temporary.appendingPathComponent("Export.mclashbackup", isDirectory: true)
        try await service.exportBackup(from: source, to: backup)
        _ = try await service.restoreBackup(from: backup, to: destination)

        let restoredStore = try ProfileStore(layout: destination)
        #expect(try await restoredStore.profiles().map(\.id) == [profile.id])
        #expect(try await restoredStore.activeProfileID() == profile.id)
        #expect(
            try await ProfileRuntimePlanStore(layout: destination).load()
                == runtimePlan
        )
        #expect(
            try String(
                contentsOf: destination.rootDirectory
                    .appendingPathComponent("Settings/sample.txt"),
                encoding: .utf8
            ) == "settings"
        )
        #expect(!FileManager.default.fileExists(atPath: destination.runtimeConfigurationURL.path))
    }

    @Test("Export refuses to recurse into application data")
    func rejectsNestedDestination() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "MClashBackupNested-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let layout = ProfileDirectoryLayout(rootDirectory: root)
        let service = ProfileBackupService()
        do {
            try await service.exportBackup(
                from: layout,
                to: root.appendingPathComponent("bad.mclashbackup", isDirectory: true)
            )
            Issue.record("Expected nested backup destination to be rejected")
        } catch let error as ProfileBackupError {
            #expect(error == .destinationInsideApplicationData)
        }
    }

    @Test("A pending restore can roll every managed file back before commit")
    func transactionRollback() async throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(
            "MClashBackupRollback-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: temporary) }
        let source = ProfileDirectoryLayout(
            rootDirectory: temporary.appendingPathComponent("Source", isDirectory: true)
        )
        let destination = ProfileDirectoryLayout(
            rootDirectory: temporary.appendingPathComponent("Destination", isDirectory: true)
        )
        let sourceStore = try ProfileStore(layout: source)
        let destinationStore = try ProfileStore(layout: destination)
        let sourceURL = temporary.appendingPathComponent("source.yaml")
        let destinationURL = temporary.appendingPathComponent("destination.yaml")
        try Data("mixed-port: 18900\n".utf8).write(to: sourceURL)
        try Data("mixed-port: 28900\n".utf8).write(to: destinationURL)
        let sourceProfile = try await sourceStore.importProfile(from: sourceURL)
        let destinationProfile = try await destinationStore.importProfile(
            from: destinationURL
        )
        try await sourceStore.setActiveProfile(sourceProfile.id)
        try await destinationStore.setActiveProfile(destinationProfile.id)

        let sourceSettings = source.rootDirectory.appendingPathComponent(
            "Settings",
            isDirectory: true
        )
        let destinationSettings = destination.rootDirectory.appendingPathComponent(
            "Settings",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: sourceSettings,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: destinationSettings,
            withIntermediateDirectories: true
        )
        try Data("incoming".utf8).write(
            to: sourceSettings.appendingPathComponent("marker.txt")
        )
        try Data("previous".utf8).write(
            to: destinationSettings.appendingPathComponent("marker.txt")
        )

        let service = ProfileBackupService()
        let backup = temporary.appendingPathComponent(
            "Rollback.mclashbackup",
            isDirectory: true
        )
        try await service.exportBackup(from: source, to: backup)
        let transaction = try await service.beginRestoreBackup(
            from: backup,
            to: destination
        )
        #expect(
            try await ProfileStore(layout: destination).activeProfileID()
                == sourceProfile.id
        )

        try await service.rollbackRestoreBackup(transaction)

        let rolledBackStore = try ProfileStore(layout: destination)
        #expect(try await rolledBackStore.profiles().map(\.id) == [destinationProfile.id])
        #expect(try await rolledBackStore.activeProfileID() == destinationProfile.id)
        #expect(
            try String(
                contentsOf: destinationSettings.appendingPathComponent("marker.txt"),
                encoding: .utf8
            ) == "previous"
        )
    }
}
