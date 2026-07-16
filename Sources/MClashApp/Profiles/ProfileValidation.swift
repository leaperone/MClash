import Foundation

/// A validation boundary for the runtime configuration. The production
/// implementation can invoke `mihomo -t -d <home> -f <configurationAt>`.
public protocol ProfileValidating: Sendable {
    func validate(configurationAt url: URL) async throws
}

public struct AcceptingProfileValidator: ProfileValidating {
    public init() {}

    public func validate(configurationAt url: URL) async throws {}
}

public struct ClosureProfileValidator: ProfileValidating {
    private let validation: @Sendable (URL) async throws -> Void

    public init(_ validation: @escaping @Sendable (URL) async throws -> Void) {
        self.validation = validation
    }

    public func validate(configurationAt url: URL) async throws {
        try await validation(url)
    }
}
