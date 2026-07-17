import Foundation

/// Observable freshness for one controller/provider data channel.
///
/// A retained numeric value is not necessarily a live value. Keeping the last
/// sample and retry context lets the UI distinguish a real 0 B/s from a stale
/// 0 B/s, and an empty connection list from a disconnected stream.
struct LiveStreamHealth: Equatable, Sendable {
    enum Phase: Equatable, Sendable {
        case inactive
        case connecting
        case live
        case reconnecting
        case stale
    }

    var phase: Phase
    var lastReceivedAt: Date?
    var lastFailureAt: Date?
    var retryAttempt: Int
    var lastError: String?

    static let inactive = LiveStreamHealth(
        phase: .inactive,
        lastReceivedAt: nil,
        lastFailureAt: nil,
        retryAttempt: 0,
        lastError: nil
    )

    static func connecting(previousSampleAt: Date? = nil) -> LiveStreamHealth {
        LiveStreamHealth(
            phase: .connecting,
            lastReceivedAt: previousSampleAt,
            lastFailureAt: nil,
            retryAttempt: 0,
            lastError: nil
        )
    }

    mutating func received(at date: Date = Date()) {
        phase = .live
        lastReceivedAt = date
        lastFailureAt = nil
        retryAttempt = 0
        lastError = nil
    }

    mutating func failed(
        _ error: Error,
        attempt: Int,
        at date: Date = Date(),
        staleAfterAttempts: Int = 3
    ) {
        retryAttempt = max(1, attempt)
        phase = retryAttempt >= max(1, staleAfterAttempts) ? .stale : .reconnecting
        lastFailureAt = date
        lastError = error.localizedDescription
    }

    mutating func stopped() {
        self = .inactive
    }

    var hasCurrentData: Bool {
        phase == .live
    }
}
