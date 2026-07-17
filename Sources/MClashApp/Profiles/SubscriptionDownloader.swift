import Foundation

public struct SubscriptionDownloadResponse: Equatable, Sendable {
    public let statusCode: Int
    public let data: Data?
    public let eTag: String?
    public let lastModified: String?
    public let suggestedUpdateIntervalHours: Int?
    public let usage: SubscriptionUsage?
    public let webPageURL: URL?

    public init(
        statusCode: Int,
        data: Data?,
        eTag: String? = nil,
        lastModified: String? = nil,
        suggestedUpdateIntervalHours: Int? = nil,
        usage: SubscriptionUsage? = nil,
        webPageURL: URL? = nil
    ) {
        self.statusCode = statusCode
        self.data = data
        self.eTag = eTag
        self.lastModified = lastModified
        self.suggestedUpdateIntervalHours = suggestedUpdateIntervalHours
        self.usage = usage
        self.webPageURL = webPageURL
    }
}

public protocol SubscriptionDownloading: Sendable {
    func download(_ request: URLRequest) async throws -> SubscriptionDownloadResponse
}

public final class URLSessionSubscriptionDownloader: SubscriptionDownloading, @unchecked Sendable {
    private let session: URLSession
    private let maximumResponseSize: Int

    public init(
        session: URLSession = .shared,
        maximumResponseSize: Int = 16 * 1_024 * 1_024
    ) {
        self.session = session
        self.maximumResponseSize = maximumResponseSize
    }

    public func download(_ request: URLRequest) async throws -> SubscriptionDownloadResponse {
        var request = request
        if request.value(forHTTPHeaderField: "User-Agent") == nil {
            request.setValue("clash.meta", forHTTPHeaderField: "User-Agent")
        }
        if request.value(forHTTPHeaderField: "Accept") == nil {
            request.setValue("application/yaml, text/yaml, text/plain", forHTTPHeaderField: "Accept")
        }

        let (bytes, response) = try await session.bytes(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            bytes.task.cancel()
            throw SubscriptionDownloadError.nonHTTPResponse
        }
        let expectedLength = httpResponse.expectedContentLength
        guard expectedLength < 0 || expectedLength <= maximumResponseSize else {
            bytes.task.cancel()
            throw SubscriptionDownloadError.responseTooLarge(maximumResponseSize)
        }

        var data = Data()
        if expectedLength > 0 {
            data.reserveCapacity(min(Int(expectedLength), maximumResponseSize))
        }
        for try await byte in bytes {
            guard data.count < maximumResponseSize else {
                bytes.task.cancel()
                throw SubscriptionDownloadError.responseTooLarge(maximumResponseSize)
            }
            data.append(byte)
        }

        return SubscriptionDownloadResponse(
            statusCode: httpResponse.statusCode,
            data: httpResponse.statusCode == 304 ? nil : data,
            eTag: httpResponse.value(forHTTPHeaderField: "ETag"),
            lastModified: httpResponse.value(forHTTPHeaderField: "Last-Modified"),
            suggestedUpdateIntervalHours: Self.updateInterval(
                from: httpResponse.value(forHTTPHeaderField: "profile-update-interval")
            ),
            usage: Self.subscriptionUsage(
                from: httpResponse.value(forHTTPHeaderField: "subscription-userinfo")
            ),
            webPageURL: Self.webPageURL(
                from: httpResponse.value(forHTTPHeaderField: "profile-web-page-url")
            )
        )
    }

    static func updateInterval(from header: String?) -> Int? {
        guard let header,
              let hours = Int(header.trimmingCharacters(in: .whitespacesAndNewlines)),
              (1...8_760).contains(hours) else {
            return nil
        }
        return hours
    }

    static func subscriptionUsage(from header: String?) -> SubscriptionUsage? {
        guard let header else { return nil }
        let fields = header.split(separator: ";").reduce(into: [String: String]()) { result, field in
            let pair = field.split(separator: "=", maxSplits: 1).map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            guard pair.count == 2, !pair[0].isEmpty else { return }
            result[pair[0].lowercased()] = pair[1]
        }

        func nonnegativeValue(_ key: String) -> Int64? {
            guard let raw = fields[key], let value = Int64(raw), value >= 0 else { return nil }
            return value
        }

        let upload = nonnegativeValue("upload")
        let download = nonnegativeValue("download")
        let total = nonnegativeValue("total")
        let expiresAt = nonnegativeValue("expire").flatMap { timestamp -> Date? in
            guard timestamp > 0 else { return nil }
            return Date(timeIntervalSince1970: TimeInterval(timestamp))
        }
        guard upload != nil || download != nil || total != nil || expiresAt != nil else {
            return nil
        }
        return SubscriptionUsage(
            upload: upload,
            download: download,
            total: total,
            expiresAt: expiresAt
        )
    }

    static func webPageURL(from header: String?) -> URL? {
        guard let value = header?.trimmingCharacters(in: .whitespacesAndNewlines),
              let url = URL(string: value),
              let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              url.host != nil else {
            return nil
        }
        return url
    }
}

public enum SubscriptionDownloadError: Error, Equatable, Sendable {
    case nonHTTPResponse
    case responseTooLarge(Int)
}

extension SubscriptionDownloadError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .nonHTTPResponse:
            "The subscription server did not return an HTTP response."
        case let .responseTooLarge(limit):
            "The subscription response exceeded the \(limit)-byte safety limit."
        }
    }
}
