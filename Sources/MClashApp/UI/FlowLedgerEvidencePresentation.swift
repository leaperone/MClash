import Foundation

enum FlowLedgerAssociationPresentation {
    static func isConfirmed(_ association: FlowLedgerAssociation?) -> Bool {
        guard case .some(.exactRelayPort) = association else { return false }
        return true
    }

    static func isProbable(_ association: FlowLedgerAssociation?) -> Bool {
        guard case .some(.destinationAndStartTime) = association else { return false }
        return true
    }

    static func title(_ association: FlowLedgerAssociation?) -> String {
        switch association {
        case let .exactRelayPort(connectionID):
            return "Confirmed by exact relay source port · \(connectionID)"
        case let .destinationAndStartTime(connectionID, difference):
            let delta = difference.formatted(
                .number.precision(.fractionLength(2))
            )
            return "Probable only · same destination and protocol · start time Δ\(delta)s · \(connectionID)"
        case .some(.none), nil:
            return "No Mihomo connection association"
        }
    }
}

enum FlowLedgerTrafficPresentation {
    static func directRouteDetail(_ traffic: FlowLedgerTrafficAggregate) -> String {
        let unmeasuredCount = traffic.notMeasuredAfterHandoffCount
        guard unmeasuredCount > 0 else {
            return "Relayed locally; payload measured"
        }

        let handoff = directHandoffTitle(unmeasuredCount)
        guard traffic.exactTotalBytes > 0 else {
            return "\(handoff) unmeasured; no measured payload yet"
        }
        return "Local relay bytes measured; \(handoff) unmeasured"
    }

    static func coverageHelp(_ traffic: FlowLedgerTrafficAggregate) -> String {
        let unmeasuredCount = traffic.notMeasuredAfterHandoffCount
        guard unmeasuredCount > 0 else {
            if traffic.notApplicableCount > 0, traffic.exactTotalBytes == 0 {
                return "These decisions did not carry payload, for example rejected flows."
            }
            return "All displayed bytes were measured by Mihomo or the App Routing relay."
        }

        let handoff = unmeasuredHandoffTitle(unmeasuredCount)
        let limitation = "\(handoff) continued outside MClash after handoff; that payload is not counted as zero."
        guard traffic.exactTotalBytes > 0 else { return limitation }

        return "\(formattedLedgerTraffic(traffic.exactTotalBytes)) was measured by Mihomo or the App Routing relay. \(limitation)"
    }

    private static func unmeasuredHandoffTitle(_ count: Int) -> String {
        "\(formattedCount(count)) pass-through or fail-open \(count == 1 ? "flow" : "flows")"
    }

    private static func directHandoffTitle(_ count: Int) -> String {
        "\(formattedCount(count)) pass-through \(count == 1 ? "flow" : "flows")"
    }

    private static func formattedLedgerTraffic(_ bytes: UInt64) -> String {
        formattedByteCount(bytes > UInt64(Int64.max) ? .max : Int64(bytes))
    }
}
