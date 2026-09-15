import Foundation

public struct XrayAccessRecord: Codable, Equatable, Hashable, Sendable, Identifiable {
    public let id: UUID
    public let timestamp: Date
    public let source: String?
    public let destination: String
    public let transport: String
    public let inbound: String?
    public let outbound: String?

    public init(id: UUID = UUID(), timestamp: Date, source: String?, destination: String,
                transport: String, inbound: String?, outbound: String?) {
        self.id = id
        self.timestamp = timestamp
        self.source = source
        self.destination = destination
        self.transport = transport
        self.inbound = inbound
        self.outbound = outbound
    }
}

public struct XrayAccessLogParser: Sendable {
    private static let formatter: DateFormatter = {
        let value = DateFormatter()
        value.locale = Locale(identifier: "en_US_POSIX")
        value.timeZone = TimeZone.current
        value.dateFormat = "yyyy/MM/dd HH:mm:ss.SSSSSS"
        return value
    }()

    public init() {}

    public func parse(_ data: Data, now: Date = Date()) -> [XrayAccessRecord] {
        String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline).compactMap {
            parse(String($0), now: now)
        }
    }

    /// Parses complete lines from an appended log chunk and retains a trailing
    /// partial line for the next chunk. Xray can flush a record in more than
    /// one write, so advancing the file offset without this buffer would drop
    /// that record permanently.
    public func parse(
        _ data: Data,
        pendingLine: inout String,
        now: Date = Date()
    ) -> [XrayAccessRecord] {
        guard !data.isEmpty else { return [] }
        let combined = pendingLine + String(decoding: data, as: UTF8.self)
        let lines = combined.split(separator: "\n", omittingEmptySubsequences: false)
        let hasTrailingNewline = combined.last == "\n"
        let completeCount = hasTrailingNewline ? lines.count - 1 : max(lines.count - 1, 0)
        pendingLine = hasTrailingNewline ? "" : String(lines.last ?? "")
        return lines.prefix(completeCount).compactMap {
            parse(String($0).trimmingCharacters(in: .whitespacesAndNewlines), now: now)
        }
    }

    public func parse(_ line: String, now: Date = Date()) -> XrayAccessRecord? {
        let parts = line.split(separator: " ", maxSplits: 4).map(String.init)
        guard parts.count >= 5, parts[2] == "from", parts[4].hasPrefix("accepted ") else { return nil }
        let date = Self.formatter.date(from: parts[0] + " " + parts[1]) ?? now
        let source = parts[3]
        let accepted = String(parts[4].dropFirst("accepted ".count))
        let routeStart = accepted.firstIndex(of: "[")
        let sourceAndTarget = String(routeStart.map { accepted[..<$0] } ?? Substring(accepted)).trimmingCharacters(in: .whitespaces)
        let route = routeStart.map { String(accepted[$0...]) }
        let transport: String
        let destination: String
        if sourceAndTarget.hasPrefix("//") {
            transport = "http"
            destination = String(sourceAndTarget.dropFirst(2))
        } else if let colon = sourceAndTarget.firstIndex(of: ":") {
            transport = String(sourceAndTarget[..<colon])
            destination = String(sourceAndTarget[sourceAndTarget.index(after: colon)...])
        } else {
            transport = "unknown"
            destination = sourceAndTarget
        }
        guard !destination.isEmpty else { return nil }
        let routeParts = route?.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).components(separatedBy: " -> ") ?? []
        return XrayAccessRecord(timestamp: date, source: source, destination: destination,
                                transport: transport, inbound: routeParts.first, outbound: routeParts.dropFirst().first)
    }
}
