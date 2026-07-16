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
            applicationSupportDirectory: directory.appending(path: "support")
        )

        #expect(try locator.locate(explicitURL: executable) == executable)
    }

    @Test("Environment path is considered")
    func environmentPathIsConsidered() {
        let locator = CoreBinaryLocator(
            environment: ["MCLASH_CORE_PATH": "/tmp/custom-mihomo"],
            applicationSupportDirectory: URL(filePath: "/tmp/support")
        )

        #expect(locator.candidateURLs().first?.path == "/tmp/custom-mihomo")
    }
}
