import Foundation
import Testing
@testable import MClashNetworkShared

@Suite("TCP relay accounting")
struct TCPRelayAccountingTests {
    @Test("Visible counters advance only at accepted and delivered boundaries")
    func visibleCountersUseCommittedBoundaries() {
        var ledger = TCPRelayByteLedger()

        ledger.recordAppRead(512)
        ledger.recordUpstreamReceived(1_024)
        #expect(ledger.appRead == 512)
        #expect(ledger.upstreamReceived == 1_024)
        #expect(ledger.uploadBytes == 0)
        #expect(ledger.downloadBytes == 0)

        ledger.recordUpstreamAccepted(384)
        ledger.recordAppDelivered(768)
        #expect(ledger.uploadBytes == 384)
        #expect(ledger.downloadBytes == 768)
    }

    @Test("Counters ignore invalid sizes and saturate instead of overflowing")
    func countersAreSaturating() {
        var ledger = TCPRelayByteLedger(
            appRead: .max - 1,
            upstreamAccepted: .max - 2,
            upstreamReceived: .max - 3,
            appDelivered: .max - 4
        )

        ledger.recordAppRead(2)
        ledger.recordUpstreamAccepted(3)
        ledger.recordUpstreamReceived(4)
        ledger.recordAppDelivered(5)
        #expect(ledger.appRead == .max)
        #expect(ledger.upstreamAccepted == .max)
        #expect(ledger.upstreamReceived == .max)
        #expect(ledger.appDelivered == .max)

        ledger.recordAppRead(0)
        ledger.recordUpstreamAccepted(-1)
        #expect(ledger.appRead == .max)
        #expect(ledger.upstreamAccepted == .max)
    }

    @Test("Half-close completion is independent of close order")
    func halfCloseOrder() {
        var applicationFirst = TCPRelayHalfCloseState()
        applicationFirst.markAppReadEnded()
        #expect(!applicationFirst.bothReadHalvesEnded)
        applicationFirst.markUpstreamReadEnded()
        #expect(applicationFirst.bothReadHalvesEnded)

        var upstreamFirst = TCPRelayHalfCloseState()
        upstreamFirst.markUpstreamReadEnded()
        #expect(!upstreamFirst.bothReadHalvesEnded)
        upstreamFirst.markAppReadEnded()
        #expect(upstreamFirst.bothReadHalvesEnded)
    }

    @Test("Duplicate half-close notifications are idempotent")
    func halfCloseIsIdempotent() {
        var state = TCPRelayHalfCloseState()
        state.markAppReadEnded()
        state.markAppReadEnded()
        state.markUpstreamReadEnded()
        state.markUpstreamReadEnded()
        #expect(state.bothReadHalvesEnded)
    }

    @Test("Mihomo setup may fail open only before handshake and payload forwarding")
    func failoverBoundary() {
        var setupFailure = TCPRelayFailoverState(unavailableFallback: .direct)
        #expect(setupFailure.canFallbackToDirect)
        setupFailure.markSOCKSHandshakeSucceeded()
        #expect(!setupFailure.canFallbackToDirect)

        var forwarded = TCPRelayFailoverState(unavailableFallback: .direct)
        forwarded.markApplicationPayloadForwarded()
        #expect(!forwarded.canFallbackToDirect)

        let reject = TCPRelayFailoverState(unavailableFallback: .reject)
        #expect(!reject.canFallbackToDirect)
    }

    @Test("Backpressure allows one independent in-flight chunk per direction")
    func boundedBackpressure() {
        var state = TCPRelayBackpressureState()
        let firstUpload = state.begin(.appToUpstream)
        let overlappingUpload = state.begin(.appToUpstream)
        let firstDownload = state.begin(.upstreamToApp)
        let overlappingDownload = state.begin(.upstreamToApp)
        #expect(firstUpload)
        #expect(!overlappingUpload)
        #expect(firstDownload)
        #expect(!overlappingDownload)

        state.end(.appToUpstream)
        let resumedUpload = state.begin(.appToUpstream)
        #expect(resumedUpload)
        #expect(state.upstreamToAppInFlight)
        state.end(.upstreamToApp)
        let resumedDownload = state.begin(.upstreamToApp)
        #expect(resumedDownload)
    }
}
