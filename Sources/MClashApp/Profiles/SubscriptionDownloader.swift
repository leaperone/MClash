import Foundation

public struct SubscriptionDownloadResponse: Equatable, Sendable {
    public let statusCode: Int
    public let data: Data?
    public let eTag: String?
    public let lastModified: String?

    public init(
        statusCode: Int,
        data: Data?,
        eTag: String? = nil,
        lastModified: String? = nil
    ) {
        self.statusCode = statusCode
        self.data = data
        self.eTag = eTag
        self.lastModified = lastModified
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

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw SubscriptionDownloadError.nonHTTPResponse
        }
        guard data.count <= maximumResponseSize else {
            throw SubscriptionDownloadError.responseTooLarge(maximumResponseSize)
        }

        return SubscriptionDownloadResponse(
            statusCode: httpResponse.statusCode,
            data: httpResponse.statusCode == 304 ? nil : data,
            eTag: httpResponse.value(forHTTPHeaderField: "ETag"),
            lastModified: httpResponse.value(forHTTPHeaderField: "Last-Modified")
        )
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
