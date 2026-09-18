import Foundation
import Testing
@testable import MClashApp

@Suite("Xray access log reader")
struct XrayAccessLogReaderTests {
    @Test("A live monitor starts at EOF instead of replaying stale access events")
    func liveMonitorSkipsExistingLines() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("access.log")
        try Data(line(1).utf8).write(to: url)
        let reader = XrayAccessLogReader(url: url, readExistingEvents: false)
        #expect(try await reader.poll().isEmpty)
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(line(2).utf8))
        try handle.close()
        #expect((try await reader.poll()).map(\.destination) == ["example2.com:443"])
    }

    @Test("Reopening a log preserves event identities without merging equal lines")
    func stableEventIdentities() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("access.log")
        try Data((line(1) + line(1)).utf8).write(to: url)
        let first = try await XrayAccessLogReader(url: url).poll()
        let reopened = try await XrayAccessLogReader(url: url).poll()
        #expect(first.count == 2)
        #expect(first.map(\.id) == reopened.map(\.id))
        #expect(Set(first.map(\.id)).count == 2)
        try Data((line(2) + line(2)).utf8).write(to: url)
        let rewritten = try await XrayAccessLogReader(url: url).poll()
        #expect(Set(first.map(\.id)).isDisjoint(with: rewritten.map(\.id)))
    }

    @Test("Opening a large existing log reads recent records without replaying old traffic")
    func readsOnlyRecentTail() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("access.log")
        try Data(line(1).utf8).write(to: url)
        let writer = try FileHandle(forWritingTo: url)
        defer { try? writer.close() }
        try writer.truncate(atOffset: 64 * 1024 * 1024)
        try writer.seekToEnd()
        try writer.write(contentsOf: Data(("\n" + line(99)).utf8))

        let reader = XrayAccessLogReader(url: url)
        #expect((try await reader.poll()).map(\.destination) == ["example99.com:443"])
        #expect(try await reader.poll().isEmpty)
    }

    @Test("Reads a large log in bounded polls")
    func boundedPolls() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("access.log")
        let lines = (0..<20).map { line($0) }.joined()
        try Data(lines.utf8).write(to: url)

        let reader = XrayAccessLogReader(url: url, maximumBytesPerPoll: 128)
        var records: [XrayAccessRecord] = []
        for _ in 0..<20 { records += try await reader.poll() }
        #expect(records.count < 20)
        #expect(records.last?.destination == "example19.com:443")
    }

    @Test("Retains partial lines across appends exactly once")
    func partialAppend() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("access.log")
        FileManager.default.createFile(atPath: url.path, contents: Data())
        let text = line(1)
        let split = text.index(text.startIndex, offsetBy: text.count / 2)
        try Data(text[..<split].utf8).write(to: url)
        let reader = XrayAccessLogReader(url: url, maximumBytesPerPoll: 10_000)
        #expect(try await reader.poll().isEmpty)
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text[split...].utf8))
        try handle.close()
        let records = try await reader.poll()
        #expect(records.count == 1)
        #expect(try await reader.poll().isEmpty)
    }

    @Test("Preserves a UTF-8 scalar split between polls")
    func splitUTF8() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("access.log")
        let bytes = Array(Data(line(7, destination: "节点.example.com").utf8))
        let split = bytes.firstIndex(of: 0xE8)! + 1
        try Data(bytes[..<split]).write(to: url)
        let reader = XrayAccessLogReader(url: url, maximumBytesPerPoll: 10_000)
        #expect(try await reader.poll().isEmpty)
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(bytes[split...]))
        try handle.close()
        #expect((try await reader.poll()).first?.destination == "节点.example.com:443")
    }

    @Test("Discards an overlong partial line and recovers")
    func overlongPartialLine() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("access.log")
        try Data(repeating: 0x78, count: 20).write(to: url)
        let reader = XrayAccessLogReader(url: url, maximumPendingLineBytes: 8)
        do {
            _ = try await reader.poll()
            Issue.record("An overlong partial line should be rejected")
        } catch let error as XrayAccessLogReaderError {
            #expect(error == .pendingLineTooLong)
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(("\n" + line(8)).utf8))
        #expect((try await reader.poll()).map(\.destination) == ["example8.com:443"])
        #expect(try await reader.poll().isEmpty)
    }

    @Test("Resets after truncation and rotation")
    func truncationAndRotation() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("access.log")
        try Data(line(1).utf8).write(to: url)
        let reader = XrayAccessLogReader(url: url)
        #expect((try await reader.poll()).count == 1)
        try Data(line(2).utf8).write(to: url)
        #expect((try await reader.poll()).count == 1)
        let rotated = directory.appendingPathComponent("access.log.1")
        try FileManager.default.moveItem(at: url, to: rotated)
        try Data(line(3).utf8).write(to: url)
        #expect((try await reader.poll()).count == 1)
    }

    @Test("Reports missing logs separately from healthy empty logs")
    func missingAndEmpty() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("access.log")
        let reader = XrayAccessLogReader(url: url)
        do {
            _ = try await reader.poll()
            Issue.record("A missing log should be reported")
        } catch let error as XrayAccessLogReaderError {
            #expect(error == .missing)
        }
        FileManager.default.createFile(atPath: url.path, contents: Data())
        #expect(try await reader.poll().isEmpty)
    }

    private func line(_ index: Int, destination: String? = nil) -> String {
        "2026/09/15 15:18:31.187050 from 127.0.0.1 accepted tcp:\(destination ?? "example\(index).com"):443 [inbound -> node]\n"
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("xray-reader-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
