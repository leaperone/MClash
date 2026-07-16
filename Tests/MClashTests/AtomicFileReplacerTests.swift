import Foundation
import Testing
@testable import MClashApp

@Suite("Atomic File Replacer")
struct AtomicFileReplacerTests {
    @Test("Rollback restores the previous file")
    func rollbackRestoresPreviousFile() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "AtomicFileReplacerTests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let destination = directory.appendingPathComponent("config.yaml")
        let original = Data("original\n".utf8)
        let replacement = Data("replacement\n".utf8)
        try original.write(to: destination)

        let replacer = AtomicFileReplacer()
        let staged = try await replacer.stage(
            data: replacement,
            in: directory.appendingPathComponent("Staging"),
            preferredName: "config.yaml"
        )
        let receipt = try await replacer.replace(
            destinationURL: destination,
            withStagedFile: staged
        )
        let installedData = try Data(contentsOf: destination)
        #expect(installedData == replacement)

        try await replacer.rollback(receipt)
        let restoredData = try Data(contentsOf: destination)
        #expect(restoredData == original)
    }

    @Test("Rollback removes a newly-created destination")
    func rollbackRemovesNewDestination() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "AtomicFileReplacerTests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let destination = directory.appendingPathComponent("config.yaml")
        let replacer = AtomicFileReplacer()
        let staged = try await replacer.stage(
            data: Data("new\n".utf8),
            in: directory.appendingPathComponent("Staging")
        )
        let receipt = try await replacer.replace(
            destinationURL: destination,
            withStagedFile: staged
        )

        try await replacer.rollback(receipt)
        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }
}
