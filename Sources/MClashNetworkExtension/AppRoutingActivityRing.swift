import Foundation
import MClashNetworkShared

/// Provider-facing name for the shared, independently testable activity ring.
/// Keeping the implementation in MClashNetworkShared lets both the system
/// extension and host-side test target use exactly the same cursor semantics.
typealias AppRoutingActivityRing = BoundedAppRoutingActivityRing

struct AppRoutingRelaySnapshot: Sendable {
    let state: AppRoutingRelayState
    let uploadBytes: UInt64
    let downloadBytes: UInt64
    let error: String?
    let localPort: UInt16?
}

/// Relay-queue-confined publisher that turns high-frequency byte updates into
/// bounded telemetry while preserving immediate lifecycle and final reports.
final class AppRoutingRelayActivityReporter: @unchecked Sendable {
    private let queue: DispatchQueue
    private let observer: @Sendable (AppRoutingRelaySnapshot) -> Void
    private var limiter = AppRoutingRelayReportLimiter()
    private var latestSnapshot: AppRoutingRelaySnapshot?
    private var scheduledReport: DispatchWorkItem?

    init(
        queue: DispatchQueue,
        observer: @escaping @Sendable (AppRoutingRelaySnapshot) -> Void
    ) {
        self.queue = queue
        self.observer = observer
    }

    func report(_ snapshot: AppRoutingRelaySnapshot) {
        latestSnapshot = snapshot
        let now = DispatchTime.now().uptimeNanoseconds
        switch limiter.decision(
            for: snapshot.state,
            uploadBytes: snapshot.uploadBytes,
            downloadBytes: snapshot.downloadBytes,
            nowNanoseconds: now
        ) {
        case .emit:
            cancelScheduledReport()
            observer(snapshot)
        case let .schedule(afterNanoseconds):
            scheduleReport(afterNanoseconds: afterNanoseconds)
        case .suppress:
            break
        }
    }

    private func scheduleReport(afterNanoseconds: UInt64) {
        guard scheduledReport == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            self?.flushScheduledReport()
        }
        scheduledReport = work
        let clampedDelay = min(afterNanoseconds, UInt64(Int.max))
        queue.asyncAfter(
            deadline: .now() + .nanoseconds(Int(clampedDelay)),
            execute: work
        )
    }

    private func flushScheduledReport() {
        scheduledReport = nil
        guard let latestSnapshot,
              latestSnapshot.state == .relaying,
              limiter.shouldEmitScheduledReport(
                  uploadBytes: latestSnapshot.uploadBytes,
                  downloadBytes: latestSnapshot.downloadBytes,
                  nowNanoseconds: DispatchTime.now().uptimeNanoseconds
              )
        else { return }
        observer(latestSnapshot)
    }

    private func cancelScheduledReport() {
        scheduledReport?.cancel()
        scheduledReport = nil
    }
}
