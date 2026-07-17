import Testing
@testable import MClashNetworkShared

@Suite("UDP relay accounting")
struct UDPRelayAccountingTests {
    @Test("Visible UDP bytes advance only at accepted and delivered boundaries")
    func deliveryBoundaryAccounting() {
        var ledger = UDPRelayByteLedger()

        ledger.recordApplicationRead(120)
        ledger.recordUpstreamReceived(240)
        #expect(ledger.uploadBytes == 0)
        #expect(ledger.downloadBytes == 0)

        ledger.recordUpstreamAccepted(120)
        ledger.recordApplicationDelivered(240)
        #expect(ledger.uploadBytes == 120)
        #expect(ledger.downloadBytes == 240)
        #expect(ledger.applicationReadBytes == 120)
        #expect(ledger.upstreamReceivedBytes == 240)
    }

    @Test("Invalid UDP byte counts are ignored")
    func invalidCountsAreIgnored() {
        var ledger = UDPRelayByteLedger()
        ledger.recordApplicationRead(-1)
        ledger.recordUpstreamAccepted(0)
        ledger.recordUpstreamReceived(-20)
        ledger.recordApplicationDelivered(0)
        #expect(ledger == UDPRelayByteLedger())
    }

    @Test("Response queue budget bounds datagram count and bytes")
    func queueBudgetIsBounded() {
        var budget = UDPRelayQueueBudget(maximumDatagrams: 2, maximumBytes: 10)
        let firstReservation = budget.reserve(bytes: 6)
        let secondReservation = budget.reserve(bytes: 4)
        let zeroReservation = budget.reserve(bytes: 0)
        #expect(firstReservation)
        #expect(secondReservation)
        #expect(!zeroReservation)
        #expect(budget.datagramCount == 2)
        #expect(budget.byteCount == 10)

        budget.release(bytes: 6)
        let resumedReservation = budget.reserve(bytes: 5)
        let overBudgetReservation = budget.reserve(bytes: 2)
        #expect(resumedReservation)
        #expect(!overBudgetReservation)
        #expect(budget.datagramCount == 2)
        #expect(budget.byteCount == 9)
    }

    @Test("Queue release is defensive against duplicate or oversized releases")
    func queueReleaseIsDefensive() {
        var budget = UDPRelayQueueBudget(maximumDatagrams: 4, maximumBytes: 20)
        let reservation = budget.reserve(bytes: 8)
        #expect(reservation)
        budget.release(bytes: 100)
        budget.release(bytes: 100)
        #expect(budget.datagramCount == 0)
        #expect(budget.byteCount == 0)
    }

    @Test("UDP fallback remains safe through association setup but closes when the flow opens")
    func udpFallbackBoundary() {
        var state = UDPRelayFailoverState(unavailableFallback: .direct)
        #expect(state.canFallbackToDirect)

        state.markFlowOpened()
        #expect(!state.canFallbackToDirect)
    }

    @Test("Reject fallback and forwarded payload never switch to Direct")
    func udpFallbackRejectsUnsafeTransitions() {
        let reject = UDPRelayFailoverState(unavailableFallback: .reject)
        #expect(!reject.canFallbackToDirect)

        var forwarded = UDPRelayFailoverState(unavailableFallback: .direct)
        forwarded.markApplicationPayloadForwarded()
        #expect(!forwarded.canFallbackToDirect)
    }
}
