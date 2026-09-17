import Foundation
import Testing
@testable import MClashApp

@MainActor
struct XrayTrafficHistoryTests {
    @Test("All events persist beyond the visible limit and retries do not add records")
    func persistentBatchAccounting() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("xray-ledger-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "MClash-XrayLedger-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = makeTestAppModel(profileDirectoryLayout: ProfileDirectoryLayout(rootDirectory: root),
                                     preferenceDefaults: defaults)
        await model.setPersistentTrafficHistoryEnabled(true)
        let now = Date()
        let records = (0..<2_205).map { _ in
            XrayAccessRecord(timestamp: now, source: "127.0.0.1:50000", destination: "example.com:443",
                             transport: "tcp", inbound: "HTTP", outbound: "node-a")
        }
        await model.ingestXrayAccessRecords(records)
        for _ in 0..<100 where model.trafficHistoryTodaySnapshot?.totals.recordedFlowCount != 2_205 {
            try await Task.sleep(for: .milliseconds(50))
        }
        let totals = try #require(model.trafficHistoryTodaySnapshot?.totals)
        #expect(totals.recordedFlowCount == 2_205)
        #expect(totals.exactTotalBytes == 0)
        #expect(totals.coverage.notMeasuredDirectionCount == 4_410)
        #expect(totals.coverage.measuredFraction == 0)
        #expect(model.xrayAccessRecords.count == 2_000)

        await model.ingestXrayAccessRecords(records)
        try await Task.sleep(for: .milliseconds(250))
        #expect(model.trafficHistoryTodaySnapshot?.totals.recordedFlowCount == 2_205)
        #expect(await model.clearTrafficHistory())
        await model.ingestXrayAccessRecords(records)
        #expect(model.xrayAccessRecords.isEmpty)
        #expect(model.trafficHistoryTodaySnapshot?.totals.recordedFlowCount == 0)
        await model.setPersistentTrafficHistoryEnabled(false)
    }
}
