import Foundation

public struct SubscriptionImportRequest: Equatable, Sendable {
    public let name: String
    public let url: URL

    public init(name: String, url: URL) {
        self.name = name
        self.url = url
    }

    /// A presentation-safe origin that never exposes subscription credentials,
    /// paths, or query parameters in the confirmation alert.
    public var displayHost: String {
        url.host ?? "Unknown host"
    }
}

public enum SubscriptionURLRouter {
    public static func parse(_ incomingURL: URL) throws -> SubscriptionImportRequest {
        guard let components = URLComponents(url: incomingURL, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(),
              scheme == "mclash" || scheme == "clash" else {
            throw SubscriptionURLRouterError.unsupportedScheme
        }
        let action = [components.host, components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))]
            .compactMap { $0?.lowercased() }
            .first { !$0.isEmpty }
        guard action == "install-config" || action == "subscribe" || action == "import" else {
            throw SubscriptionURLRouterError.unsupportedAction
        }
        let query = Dictionary(
            components.queryItems?.compactMap { item -> (String, String)? in
                guard let value = item.value else { return nil }
                return (item.name.lowercased(), value)
            } ?? [],
            uniquingKeysWith: { first, _ in first }
        )
        guard let rawURL = query["url"],
              let subscriptionURL = URL(string: rawURL),
              let subscriptionScheme = subscriptionURL.scheme?.lowercased(),
              subscriptionScheme == "https",
              subscriptionURL.host?.isEmpty == false else {
            throw SubscriptionURLRouterError.invalidSubscriptionURL
        }
        let proposedName = query["name"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = proposedName?.isEmpty == false
            ? proposedName!
            : (subscriptionURL.host ?? "Subscription")
        return SubscriptionImportRequest(name: name, url: subscriptionURL)
    }
}

public enum SubscriptionURLRouterError: Error, Equatable, LocalizedError, Sendable {
    case unsupportedScheme
    case unsupportedAction
    case invalidSubscriptionURL

    public var errorDescription: String? {
        switch self {
        case .unsupportedScheme:
            "This URL is not an MClash subscription link."
        case .unsupportedAction:
            "This MClash URL action is not supported."
        case .invalidSubscriptionURL:
            "The subscription link does not contain a valid HTTPS URL."
        }
    }
}
