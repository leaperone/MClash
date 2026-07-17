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
