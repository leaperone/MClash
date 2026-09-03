import Foundation

/// Provides a deterministic order for a connection snapshot before SwiftUI
/// renders it.  The controller normally sends newest-first, but that order is
/// not part of the API contract and can change while a snapshot is frozen.
/// Using the start timestamp and ID as tie breakers keeps rows (and therefore
/// selection) in place when the source returns the same connections in a
/// different order.
enum ConnectionSnapshotOrdering {
    static func stableNewestFirst(_ connections: [MihomoConnection]) -> [MihomoConnection] {
        connections.sorted { lhs, rhs in
            let lhsDate = RuntimeTimestampParser.date(from: lhs.start)
            let rhsDate = RuntimeTimestampParser.date(from: rhs.start)
            switch (lhsDate, rhsDate) {
            case let (.some(left), .some(right)) where left != right:
                return left > right
            case (.some, .none):
                return true
            case (.none, .some):
                return false
            default:
                return lhs.id < rhs.id
            }
        }
    }
}
