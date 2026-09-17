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
            parse(String($0).trimmingCharacters(in: .whitespacesAndNewlines), now: now)
        }
    }

    public func parse(_ line: String, now: Date = Date(), id: UUID = UUID()) -> XrayAccessRecord? {
        let parts = line.split(maxSplits: 4, whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard parts.count >= 5, parts[2] == "from", parts[4].hasPrefix("accepted ") else { return nil }
        let date = Self.formatter.date(from: parts[0] + " " + parts[1]) ?? now
        let source = parts[3]
        let accepted = String(parts[4].dropFirst("accepted ".count))
        let targetParts = accepted.split(maxSplits: 1, whereSeparator: { $0 == " " || $0 == "\t" })
        guard let targetPart = targetParts.first, !targetPart.isEmpty else { return nil }
        let sourceAndTarget = String(targetPart)
        let trailing = targetParts.count == 2 ? String(targetParts[1]).trimmingCharacters(in: .whitespaces) : ""
        let transport: String
        let destination: String
        if sourceAndTarget.hasPrefix("//") {
            transport = "http"
            destination = String(sourceAndTarget.dropFirst(2))
        } else if let colon = sourceAndTarget.firstIndex(of: ":") {
            let scheme = String(sourceAndTarget[..<colon]).lowercased()
            guard ["tcp", "udp", "http", "https"].contains(scheme) else { return nil }
            transport = scheme == "https" ? "http" : scheme
            let value = String(sourceAndTarget[sourceAndTarget.index(after: colon)...])
            destination = value.hasPrefix("//") ? String(value.dropFirst(2)) : value
        } else {
            return nil
        }
        guard !destination.isEmpty else { return nil }
        let route: (inbound: String, outbound: String)?
        if trailing.hasPrefix("[") {
            guard let closing = trailing.firstIndex(of: "]") else { return nil }
            let routeBody = String(trailing[trailing.index(after: trailing.startIndex)..<closing])
            let separator = [" ==> ", " -> ", " >> "].first { routeBody.contains($0) }
            let routeParts = (separator.map { routeBody.components(separatedBy: $0) } ?? [routeBody]).map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            guard routeParts.count == 2, let inbound = routeParts.first, !inbound.isEmpty,
                  let outbound = routeParts.last, !outbound.isEmpty else { return nil }
            route = (inbound, outbound)
        } else {
            route = nil
        }
        let inbound = route?.inbound
        guard inbound != "dns-query", !(inbound?.hasPrefix("probe-") ?? false) else { return nil }
        return XrayAccessRecord(id: id, timestamp: date, source: source, destination: destination,
                                transport: transport, inbound: inbound,
                                outbound: route?.outbound)
    }
}
