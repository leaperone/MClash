import Foundation
import Testing
@testable import MClashApp

@Suite("Xray log retention")
struct XrayLogRetentionTests {
    @Test("Small logs are left untouched and do not restart LoggerService")
    func skipsSmallLogs() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try Data("small".utf8).write(to: fixture.access)
        let restart = RestartProbe()
        let retention = XrayLogRetention(directory: fixture.directory, restartLogger: { await restart.record() })
        #expect(try await retention.rotateIfNeeded() == false)
        #expect(await restart.count == 0)
        #expect(!FileManager.default.fileExists(atPath: fixture.previous.path))
    }

    @Test("Rotation renames both files before one restart and creates fresh active paths")
    func rotatesLogs() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try Data(repeating: 0x61, count: XrayLogRetention.targetBytes + 1).write(to: fixture.access)
        try Data(repeating: 0x62, count: XrayLogRetention.targetBytes + 1).write(to: fixture.error)
        let restart = RestartProbe()
        let retention = XrayLogRetention(directory: fixture.directory, restartLogger: {
            guard !FileManager.default.fileExists(atPath: fixture.access.path),
                  !FileManager.default.fileExists(atPath: fixture.error.path) else {
                throw TestError.activePathStillPresent
            }
            await restart.record()
        })
        #expect(try await retention.rotateIfNeeded())
        #expect(await restart.count == 1)
        #expect(FileManager.default.fileExists(atPath: fixture.access.path))
        #expect(FileManager.default.fileExists(atPath: fixture.error.path))
        #expect(try Data(contentsOf: fixture.previous).count == XrayLogRetention.targetBytes + 1)
        #expect(try Data(contentsOf: fixture.errorPrevious).count == XrayLogRetention.targetBytes + 1)
    }

    @Test("An open writer continues on the renamed previous inode")
    func preservesOpenWriterTarget() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try Data(repeating: 0x61, count: XrayLogRetention.targetBytes + 1).write(to: fixture.access)
        let oldWriter = try FileHandle(forWritingTo: fixture.access)
        try oldWriter.seekToEnd()
        let retention = XrayLogRetention(directory: fixture.directory, restartLogger: {})
        #expect(try await retention.rotateIfNeeded())
        try oldWriter.write(contentsOf: Data("tail".utf8))
        try oldWriter.close()
        let previous = try Data(contentsOf: fixture.previous)
        let active = try Data(contentsOf: fixture.access)
        #expect(previous.suffix(4) == Data("tail".utf8))
        #expect(active.isEmpty)
    }

    @Test("A failed restart restores readable active logs")
    func restoresOnFailure() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try Data(repeating: 0x61, count: XrayLogRetention.targetBytes + 1).write(to: fixture.access)
        let retention = XrayLogRetention(directory: fixture.directory, restartLogger: { throw TestError.failed })
        await #expect(throws: XrayLogRetentionError.restartFailed) { try await retention.rotateIfNeeded() }
        #expect(FileManager.default.fileExists(atPath: fixture.access.path))
        #expect(!FileManager.default.fileExists(atPath: fixture.previous.path))
        #expect(try Data(contentsOf: fixture.access).count == XrayLogRetention.targetBytes + 1)
    }

    @Test("A restart timeout preserves a newly created canonical writer and old archive")
    func preservesNewWriterAfterUncertainRestart() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try Data(repeating: 0x61, count: XrayLogRetention.targetBytes + 1).write(to: fixture.access)
        let retention = XrayLogRetention(directory: fixture.directory, restartLogger: {
            try Data("new-record".utf8).write(to: fixture.access, options: .withoutOverwriting)
            throw TestError.failed
        })
        await #expect(throws: XrayLogRetentionError.restartFailed) { try await retention.rotateIfNeeded() }
        #expect(try String(contentsOf: fixture.access, encoding: .utf8) == "new-record")
        #expect(try Data(contentsOf: fixture.previous).count == XrayLogRetention.targetBytes + 1)
    }

    @Test("Concurrent rotation requests are serialized")
    func serializesConcurrentRequests() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try Data(repeating: 0x61, count: XrayLogRetention.targetBytes + 1).write(to: fixture.access)
        let retention = XrayLogRetention(directory: fixture.directory, restartLogger: {
            try await Task.sleep(for: .milliseconds(100))
        })
        let first = Task { try await retention.rotateIfNeeded() }
        try await Task.sleep(for: .milliseconds(10))
        await #expect(throws: XrayLogRetentionError.alreadyRotating) {
            try await retention.rotateIfNeeded()
        }
        #expect(try await first.value)
    }

    @Test("A pre-existing previous file is replaced and symlink paths are never touched")
    func protectsOwnedPaths() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try Data("old".utf8).write(to: fixture.previous)
        try Data(repeating: 0x61, count: XrayLogRetention.targetBytes + 1).write(to: fixture.access)
        let retention = XrayLogRetention(directory: fixture.directory, restartLogger: {})
        #expect(try await retention.rotateIfNeeded())
        #expect(try String(contentsOf: fixture.previous, encoding: .utf8).hasPrefix("a"))

        let symlinkTarget = fixture.directory.appendingPathComponent("outside.log")
        try Data(repeating: 0x62, count: XrayLogRetention.targetBytes + 1).write(to: symlinkTarget)
        try FileManager.default.removeItem(at: fixture.access)
        try FileManager.default.createSymbolicLink(at: fixture.access, withDestinationURL: symlinkTarget)
        #expect(try await retention.rotateIfNeeded() == false)
        #expect(try Data(contentsOf: symlinkTarget).count == XrayLogRetention.targetBytes + 1)

        try FileManager.default.createSymbolicLink(
            atPath: fixture.errorPrevious.path,
            withDestinationPath: "missing-error.log"
        )
        try Data(repeating: 0x63, count: XrayLogRetention.targetBytes + 1).write(to: fixture.error)
        await #expect(throws: XrayLogRetentionError.unsafePath("error.log.previous")) {
            try await retention.rotateIfNeeded()
        }
    }

    private final class Fixture: @unchecked Sendable {
        let directory: URL
        let access: URL
        let error: URL
        let previous: URL
        let errorPrevious: URL

        init() throws {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent("mclash-log-retention-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            access = directory.appendingPathComponent("access.log")
            error = directory.appendingPathComponent("error.log")
            previous = directory.appendingPathComponent("access.log.previous")
            errorPrevious = directory.appendingPathComponent("error.log.previous")
        }

        func remove() { try? FileManager.default.removeItem(at: directory) }
    }
}

private enum TestError: Error, Sendable {
    case failed
    case activePathStillPresent
}

private actor RestartProbe {
    private(set) var count = 0
    func record() { count += 1 }
}
