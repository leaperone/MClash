import Foundation
import Testing
@testable import MClashApp

@Suite("Core binary location")
struct CoreBinaryLocatorTests {
    @Test("Explicit executable takes precedence")
    func explicitExecutableTakesPrecedence() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let executable = directory.appending(path: "core")
        FileManager.default.createFile(atPath: executable.path, contents: Data("test".utf8))
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executable.path
        )

        let locator = CoreBinaryLocator(
            environment: [:],
            applicationSupportDirectory: directory.appending(path: "support"),
            bundledBinaryURLs: []
        )

        #expect(try locator.locate(explicitURL: executable) == executable)
    }

    @Test("Environment path is considered")
    func environmentPathIsConsidered() {
        let locator = CoreBinaryLocator(
            environment: ["MCLASH_CORE_PATH": "/tmp/custom-mihomo"],
            applicationSupportDirectory: URL(filePath: "/tmp/support"),
            bundledBinaryURLs: [],
            developmentOverridesEnabled: true
        )

        #expect(locator.candidateURLs().first?.path == "/tmp/custom-mihomo")
    }

    @Test("Bundled core takes precedence over a hidden environment override")
    func bundledCorePrecedesEnvironmentOverride() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let bundled = try makeExecutable(named: "bundled-core", in: directory)
        let hiddenOverride = try makeExecutable(named: "hidden-override", in: directory)
        let locator = CoreBinaryLocator(
            environment: ["MCLASH_CORE_PATH": hiddenOverride.path],
            applicationSupportDirectory: directory.appending(path: "support"),
            bundledBinaryURLs: [bundled],
            developmentOverridesEnabled: true
        )

        #expect(try locator.locate() == bundled)
        #expect(Array(locator.candidateURLs().prefix(2)) == [bundled, hiddenOverride])
    }

    @Test("Broken hidden override cannot obscure a valid bundled core")
    func brokenHiddenOverrideFallsBackToBundledCore() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let bundled = try makeExecutable(named: "bundled-core", in: directory)
        let hiddenOverride = directory.appending(path: "broken-override")
        try Data("not executable".utf8).write(to: hiddenOverride)
        let locator = CoreBinaryLocator(
            environment: ["MCLASH_CORE_PATH": hiddenOverride.path],
            applicationSupportDirectory: directory.appending(path: "support"),
            bundledBinaryURLs: [bundled],
            developmentOverridesEnabled: true
        )

        #expect(try locator.locate() == bundled)
    }

    @Test("A broken override is skipped when a later fallback is executable")
    func brokenOverrideDoesNotStopFallbackSearch() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let hiddenOverride = directory.appending(path: "broken-override")
        try Data("not executable".utf8).write(to: hiddenOverride)
        let supportDirectory = directory.appending(path: "support")
        let supportCoreDirectory = supportDirectory.appending(path: "Core")
        try FileManager.default.createDirectory(
            at: supportCoreDirectory,
            withIntermediateDirectories: true
        )
        let fallback = try makeExecutable(named: "mihomo-alpha", in: supportCoreDirectory)
        let locator = CoreBinaryLocator(
            environment: ["MCLASH_CORE_PATH": hiddenOverride.path],
            applicationSupportDirectory: supportDirectory,
            bundledBinaryURLs: [],
            developmentOverridesEnabled: true
        )

        #expect(try locator.locate() == fallback)
    }

    @Test("Production discovery ignores hidden core overrides")
    func productionDiscoveryIgnoresOverrides() {
        let locator = CoreBinaryLocator(
            environment: ["MCLASH_CORE_PATH": "/tmp/custom-mihomo"],
            applicationSupportDirectory: URL(filePath: "/tmp/support"),
            bundledBinaryURLs: [],
            developmentOverridesEnabled: false
        )

        #expect(locator.candidateURLs().isEmpty)
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func makeExecutable(named name: String, in directory: URL) throws -> URL {
        let executable = directory.appending(path: name)
        try Data("test".utf8).write(to: executable)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executable.path
        )
        return executable
    }
}
