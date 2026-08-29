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
            return AppLocalization.format(
                "Confirmed by exact relay source port · %@",
                connectionID
            )
        case let .destinationAndStartTime(connectionID, difference):
            let delta = difference.formatted(
                .number
                    .precision(.fractionLength(2))
                    .locale(AppLocalization.selectedLocale)
            )
            return AppLocalization.format(
                "Probable only · same destination and protocol · start time Δ%@s · %@",
                delta,
                connectionID
            )
        case .some(.none), nil:
            return AppLocalization.string("No Mihomo connection association")
        }
    }
}

enum FlowLedgerTrafficPresentation {
    static func directRouteDetail(_ traffic: FlowLedgerTrafficAggregate) -> String {
        let unmeasuredCount = traffic.notMeasuredAfterHandoffCount
        guard unmeasuredCount > 0 else {
            return AppLocalization.string("Relayed locally; payload measured")
        }

        let handoff = directHandoffTitle(unmeasuredCount)
        guard traffic.exactTotalBytes > 0 else {
            return AppLocalization.format(
                "%@ unmeasured; no measured payload yet",
                handoff
            )
        }
        return AppLocalization.format(
            "Local relay bytes measured; %@ unmeasured",
            handoff
        )
    }

    static func coverageHelp(_ traffic: FlowLedgerTrafficAggregate) -> String {
        let unmeasuredCount = traffic.notMeasuredAfterHandoffCount
        guard unmeasuredCount > 0 else {
            if traffic.notApplicableCount > 0, traffic.exactTotalBytes == 0 {
                return AppLocalization.string(
                    "These decisions did not carry payload, for example rejected flows."
                )
            }
            return AppLocalization.string(
                "All displayed bytes were measured by Mihomo or the App Routing relay."
            )
        }

        let handoff = unmeasuredHandoffTitle(unmeasuredCount)
        let limitation = AppLocalization.format(
            "%@ continued outside MClash after handoff; that payload is not counted as zero.",
            handoff
        )
        guard traffic.exactTotalBytes > 0 else { return limitation }

        return AppLocalization.format(
            "%@ was measured by Mihomo or the App Routing relay. %@",
            formattedLedgerTraffic(traffic.exactTotalBytes),
            limitation
        )
    }

    private static func unmeasuredHandoffTitle(_ count: Int) -> String {
        AppLocalization.format(
            count == 1
                ? "%@ pass-through or fail-open flow"
                : "%@ pass-through or fail-open flows",
            formattedCount(count)
        )
    }

    private static func directHandoffTitle(_ count: Int) -> String {
        AppLocalization.format(
            count == 1 ? "%@ pass-through flow" : "%@ pass-through flows",
            formattedCount(count)
        )
    }

    private static func formattedLedgerTraffic(_ bytes: UInt64) -> String {
        formattedByteCount(bytes > UInt64(Int64.max) ? .max : Int64(bytes))
    }
}
