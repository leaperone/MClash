import Foundation
import Darwin
import CryptoKit

public enum XrayAccessLogReaderError: Error, Equatable, LocalizedError, Sendable {
    case missing
    case unreadable(String)
    case pendingLineTooLong

    public var errorDescription: String? {
        switch self {
        case .missing: AppLocalization.string("Xray access log is not available")
        case let .unreadable(message): AppLocalization.format("Could not read Xray access log: %@", message)
        case .pendingLineTooLong: AppLocalization.string("Xray access log contains an overlong partial line")
        }
    }
}

public actor XrayAccessLogReader {
    private struct ModificationTime: Equatable {
        let seconds: Int
        let nanoseconds: Int
    }

    public static let defaultMaximumBytesPerPoll = 256 * 1024
    public static let defaultMaximumPendingLineBytes = 1 * 1024 * 1024

    private let url: URL
    private let maximumBytesPerPoll: Int
    private let maximumPendingLineBytes: Int
    private let readExistingEvents: Bool
    private var fileID: UInt64?
    private var modificationTime: ModificationTime?
    private var offset: UInt64 = 0
    private var pendingBytes = Data()
    private var discardUntilNewline = false
    private let parser = XrayAccessLogParser()

    public init(url: URL, maximumBytesPerPoll: Int = XrayAccessLogReader.defaultMaximumBytesPerPoll,
                maximumPendingLineBytes: Int = XrayAccessLogReader.defaultMaximumPendingLineBytes,
                readExistingEvents: Bool = true) {
        self.url = url
        self.maximumBytesPerPoll = max(1, maximumBytesPerPoll)
        self.maximumPendingLineBytes = max(1, maximumPendingLineBytes)
        self.readExistingEvents = readExistingEvents
    }

    public func poll() throws -> [XrayAccessRecord] {
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: url)
        } catch {
            if !FileManager.default.fileExists(atPath: url.path) || (error as NSError).code == NSFileNoSuchFileError {
                throw XrayAccessLogReaderError.missing
            }
            throw XrayAccessLogReaderError.unreadable(error.localizedDescription)
        }
        defer { try? handle.close() }
        var fileInfo = stat()
        guard fstat(handle.fileDescriptor, &fileInfo) == 0 else {
            throw XrayAccessLogReaderError.unreadable(String(cString: strerror(errno)))
        }
        guard fileInfo.st_mode & S_IFMT == S_IFREG else {
            throw XrayAccessLogReaderError.unreadable("The connection log is not a regular file.")
        }
        let size = UInt64(max(0, fileInfo.st_size))
        let currentFileID = UInt64(fileInfo.st_ino)
        let currentModificationTime = ModificationTime(
            seconds: fileInfo.st_mtimespec.tv_sec,
            nanoseconds: fileInfo.st_mtimespec.tv_nsec
        )
        let isFirstRead = fileID == nil
        let isNewFile = currentFileID != fileID
        let wasRewritten = size <= offset && currentModificationTime != modificationTime
        if isNewFile || size < offset || wasRewritten {
            fileID = currentFileID
            if isFirstRead, !readExistingEvents {
                // A live monitor must not present stale access-log lines as
                // connections created by this app session. Persistent history
                // owns older records; this reader starts at the current EOF.
                offset = size
                discardUntilNewline = false
            } else if isFirstRead, size > UInt64(maximumBytesPerPoll) {
                offset = size - UInt64(maximumBytesPerPoll)
                discardUntilNewline = true
            } else {
                offset = 0
                discardUntilNewline = false
            }
            pendingBytes = Data()
        }
        modificationTime = currentModificationTime
        guard size > offset else { return [] }
        let bytesToRead = min(UInt64(maximumBytesPerPoll), size - offset)
        do {
            try handle.seek(toOffset: offset)
            let data = try handle.read(upToCount: Int(bytesToRead)) ?? Data()
            offset += UInt64(data.count)
            pendingBytes.append(data)
            var records: [XrayAccessRecord] = []
            if discardUntilNewline {
                guard let newline = pendingBytes.firstIndex(of: 0x0A) else {
                    pendingBytes = Data()
                    return []
                }
                pendingBytes.removeSubrange(...newline)
                discardUntilNewline = false
            }
            var searchStart = pendingBytes.startIndex
            var processedEnd = pendingBytes.startIndex
            let pendingOffset = offset - UInt64(pendingBytes.count)
            while let newline = pendingBytes[searchStart...].firstIndex(of: 0x0A) {
                let line = pendingBytes[searchStart..<newline]
                let lineOffset = pendingOffset + UInt64(searchStart - pendingBytes.startIndex)
                // Reopening the same log preserves identity. Equal lines at
                // different offsets still represent distinct events.
                var digest = SHA256()
                digest.update(data: Data("\(url.path)|\(fileInfo.st_dev)|\(currentFileID)|\(lineOffset)|".utf8))
                digest.update(data: line)
                let bytes = Array(digest.finalize().prefix(16))
                let id = UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                                     bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
                if let text = String(data: line, encoding: .utf8), let record = parser.parse(text, id: id) {
                    records.append(record)
                }
                processedEnd = pendingBytes.index(after: newline)
                searchStart = processedEnd
            }
            if processedEnd > pendingBytes.startIndex {
                pendingBytes.removeSubrange(pendingBytes.startIndex..<processedEnd)
            }
            guard pendingBytes.count <= maximumPendingLineBytes else {
                pendingBytes = Data()
                discardUntilNewline = true
                throw XrayAccessLogReaderError.pendingLineTooLong
            }
            return records
        } catch let error as XrayAccessLogReaderError {
            throw error
        } catch {
            throw XrayAccessLogReaderError.unreadable(error.localizedDescription)
        }
    }
}
