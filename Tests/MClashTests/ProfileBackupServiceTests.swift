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
}
