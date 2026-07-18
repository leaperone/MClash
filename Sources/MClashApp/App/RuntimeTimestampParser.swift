import Foundation

/// Lightweight, concurrency-safe parsing for timestamps emitted by Mihomo.
///
/// `ISO8601DateFormatter` performs expensive ICU setup. Keeping reusable value
/// format styles here avoids constructing formatter objects for every
/// connection row and every flow-ledger refresh.
enum RuntimeTimestampParser {
    private static let fractionalStyle = Date.ISO8601FormatStyle(
        includingFractionalSeconds: true
    )
    private static let standardStyle = Date.ISO8601FormatStyle()

    static func date(from value: String) -> Date? {
        if let date = try? fractionalStyle.parse(value) {
            return date
        }
        return try? standardStyle.parse(value)
    }
}
