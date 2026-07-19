import Foundation
import MClashNetworkShared

struct AppRoutingByteRate: Equatable, Sendable {
    var upload: UInt64 = 0
    var download: UInt64 = 0

    var total: UInt64 {
        let (value, overflow) = upload.addingReportingOverflow(download)
        return overflow ? .max : value
    }

    mutating func add(upload: UInt64, download: UInt64) {
        self.upload = saturatingAdd(self.upload, upload)
        self.download = saturatingAdd(self.download, download)
    }

    private func saturatingAdd(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
        let (value, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? .max : value
    }
}

enum AppRoutingTrafficPath: Hashable, Sendable {
    case mihomo(MihomoRoute)
    case direct
    case failOpen
    case rejected
}

struct AppRoutingTrafficRateSnapshot: Equatable, Sendable {
    static let zero = AppRoutingTrafficRateSnapshot(
        sampledAt: nil,
        interval: 0,
        measured: AppRoutingByteRate(),
        direct: AppRoutingByteRate(),
        byRule: [:],
        byApplication: [:],
        byPath: [:],
        byFlow: [:]
    )

    let sampledAt: Date?
    let interval: TimeInterval
    let measured: AppRoutingByteRate
    let direct: AppRoutingByteRate
    let byRule: [String: AppRoutingByteRate]
    let byApplication: [String: AppRoutingByteRate]
    let byPath: [AppRoutingTrafficPath: AppRoutingByteRate]
    /// Current delivered-byte rate for each live provider-owned flow.
    let byFlow: [UUID: AppRoutingByteRate]
}

struct AppRoutingTrafficRateTracker: Sendable {
    private struct Baseline: Sendable {
        let upload: UInt64
        let download: UInt64
    }

    private var baselines: [UUID: Baseline] = [:]
    private var previousSampleAt: Date?

    mutating func ingest(
        _ activities: [AppRoutingActivity],
        at sampledAt: Date = Date()
    ) -> AppRoutingTrafficRateSnapshot {
        let interval = previousSampleAt.map {
            sampledAt.timeIntervalSince($0)
        } ?? 0
        previousSampleAt = sampledAt

        var nextBaselines: [UUID: Baseline] = [:]
        nextBaselines.reserveCapacity(activities.count)
        var measuredBytes = AppRoutingByteRate()
        var directBytes = AppRoutingByteRate()
        var byRuleBytes: [String: AppRoutingByteRate] = [:]
        var byApplicationBytes: [String: AppRoutingByteRate] = [:]
        var byPathBytes: [AppRoutingTrafficPath: AppRoutingByteRate] = [:]
        var byFlowBytes: [UUID: AppRoutingByteRate] = [:]

        for activity in activities where activity.payloadBytesAreMeasured == true {
            let current = Baseline(
                upload: activity.uploadBytes,
                download: activity.downloadBytes
            )
            nextBaselines[activity.flowIdentifier] = current
            if activity.isLiveManagedFlow {
                byFlowBytes[activity.flowIdentifier] = AppRoutingByteRate()
            }
            guard let previous = baselines[activity.flowIdentifier], interval > 0 else {
                continue
            }
            let upload = current.upload >= previous.upload
                ? current.upload - previous.upload
                : 0
            let download = current.download >= previous.download
                ? current.download - previous.download
                : 0
            guard upload > 0 || download > 0 else { continue }

            measuredBytes.add(upload: upload, download: download)
            if activity.effectiveAction == .direct {
                directBytes.add(upload: upload, download: download)
            }
            if let rule = activity.matchedRuleIdentifier {
                byRuleBytes[rule, default: AppRoutingByteRate()].add(
                    upload: upload,
                    download: download
                )
            }
            byApplicationBytes[Self.applicationKey(activity), default: AppRoutingByteRate()]
                .add(upload: upload, download: download)
            byPathBytes[Self.path(activity.effectiveAction), default: AppRoutingByteRate()]
                .add(upload: upload, download: download)
            if activity.isLiveManagedFlow {
                byFlowBytes[activity.flowIdentifier]?.add(
                    upload: upload,
                    download: download
                )
            }
        }
        baselines = nextBaselines

        guard interval > 0 else { return .zero }
        return AppRoutingTrafficRateSnapshot(
            sampledAt: sampledAt,
            interval: interval,
            measured: Self.rate(measuredBytes, interval: interval),
            direct: Self.rate(directBytes, interval: interval),
            byRule: byRuleBytes.mapValues { Self.rate($0, interval: interval) },
            byApplication: byApplicationBytes.mapValues { Self.rate($0, interval: interval) },
            byPath: byPathBytes.mapValues { Self.rate($0, interval: interval) },
            byFlow: byFlowBytes.mapValues { Self.rate($0, interval: interval) }
        )
    }

    mutating func reset() {
        baselines.removeAll(keepingCapacity: true)
        previousSampleAt = nil
    }

    private static func rate(
        _ bytes: AppRoutingByteRate,
        interval: TimeInterval
    ) -> AppRoutingByteRate {
        AppRoutingByteRate(
            upload: bytesPerSecond(bytes.upload, interval: interval),
            download: bytesPerSecond(bytes.download, interval: interval)
        )
    }

    private static func bytesPerSecond(
        _ bytes: UInt64,
        interval: TimeInterval
    ) -> UInt64 {
        guard interval.isFinite, interval > 0 else { return 0 }
        let value = Double(bytes) / interval
        guard value.isFinite, value > 0 else { return 0 }
        return value >= Double(UInt64.max) ? .max : UInt64(value.rounded())
    }

    private static func applicationKey(_ activity: AppRoutingActivity) -> String {
        activity.source.bundleIdentifier
            ?? activity.source.executablePath
            ?? activity.source.signingIdentifier
            ?? "PID \(activity.source.processIdentifier)"
    }

    private static func path(_ disposition: FlowTrafficDisposition) -> AppRoutingTrafficPath {
        switch disposition {
        case let .mihomo(route): .mihomo(route)
        case .direct: .direct
        case .failOpen: .failOpen
        case .reject: .rejected
        }
    }
}
