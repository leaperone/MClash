import Foundation
import Testing
@testable import MClashApp

@Suite("Presentation telemetry policy")
struct PresentationTelemetryPolicyTests {
    @Test("Activity polling restarts at most once for an uncovered dropped gap")
    func activityPollCursorBoundsResynchronization() {
        var cursor = AppModel.AppRoutingActivityPollCursor(cursor: 0)

        let firstRestart = cursor.observe(droppedBefore: 200)
        let secondRestart = cursor.observe(droppedBefore: 201)
        #expect(firstRestart)
        #expect(!secondRestart)
        #expect(cursor.requiresStateReset)
        #expect(cursor.droppedDelta == 201)
        #expect(cursor.committed == 201)

        cursor.advance(to: 450)
        let caughtUpRestart = cursor.observe(droppedBefore: 250)
        #expect(!caughtUpRestart)
        #expect(cursor.droppedDelta == 201)
        #expect(cursor.committed == 450)
    }

    @Test("An explicit clear acknowledges its dropped watermark while retaining active flows")
    func activityPollCursorAcknowledgesExplicitClear() {
        var cursor = AppModel.AppRoutingActivityPollCursor(
            cursor: 0,
            acknowledgedDroppedBefore: 200
        )

        let acknowledgedRestart = cursor.observe(droppedBefore: 200)
        #expect(!acknowledgedRestart)
        cursor.advance(to: 25)
        #expect(cursor.committed == 200)
        #expect(cursor.droppedDelta == 0)
        #expect(!cursor.requiresStateReset)
    }

    @Test("Lightweight mode ignores a retained menu panel's stale visibility")
    @MainActor
    func lightweightModeSuppressesMenuTelemetry() throws {
        let suite = "PresentationTelemetryPolicyTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = makeTestAppModel(preferenceDefaults: defaults)

        model.setMenuBarContentVisible(true)
        #expect(model.presentationTelemetryPolicy.hasControllerStreams)

        model.lightweightMode = true
        #expect(model.presentationTelemetryPolicy == .init())

        model.lightweightMode = false
        #expect(model.presentationTelemetryPolicy == .init())
    }

    @Test("No presentation surface leaves controller telemetry dormant")
    func backgroundPolicyIsDormant() {
        let policy = AppModel.PresentationTelemetryPolicy.resolve(
            mainWindowVisible: false,
            menuBarContentVisible: false,
            destination: .connections,
            appRoutingActivityVisible: true
        )

        #expect(policy == .init())
        #expect(!policy.hasControllerStreams)
    }

    @Test("The menu popover requests quick metrics but not logs or the full ledger")
    func menuBarPolicyIsLightweight() {
        let policy = AppModel.PresentationTelemetryPolicy.resolve(
            mainWindowVisible: false,
            menuBarContentVisible: true,
            destination: .logs,
            appRoutingActivityVisible: true
        )

        #expect(policy.traffic)
        #expect(policy.connections)
        #expect(policy.proxies)
        #expect(!policy.logs)
        #expect(!policy.appRoutingActivity)
    }

    @Test("Proxy status menu bar style keeps only quick metrics live")
    func menuBarStatusPolicyIsLightweight() {
        let policy = AppModel.PresentationTelemetryPolicy.resolve(
            mainWindowVisible: false,
            menuBarContentVisible: false,
            destination: nil,
            appRoutingActivityVisible: false,
            menuBarStatusVisible: true
        )

        #expect(policy.traffic)
        #expect(policy.connections)
        #expect(!policy.proxies)
        #expect(!policy.logs)
        #expect(!policy.appRoutingActivity)
    }

    @Test("Only the selected main-window destination requests its expensive streams")
    func destinationPolicyIsSelective() {
        let logs = AppModel.PresentationTelemetryPolicy.resolve(
            mainWindowVisible: true,
            menuBarContentVisible: false,
            destination: .logs,
            appRoutingActivityVisible: false
        )
        #expect(logs.logs)
        #expect(!logs.traffic)
        #expect(!logs.connections)
        #expect(!logs.proxies)
        #expect(!logs.appRoutingActivity)

        let appRoutingRules = AppModel.PresentationTelemetryPolicy.resolve(
            mainWindowVisible: true,
            menuBarContentVisible: false,
            destination: .appRouting,
            appRoutingActivityVisible: false
        )
        #expect(appRoutingRules == .init())

        let appRoutingActivity = AppModel.PresentationTelemetryPolicy.resolve(
            mainWindowVisible: true,
            menuBarContentVisible: false,
            destination: .appRouting,
            appRoutingActivityVisible: true
        )
        #expect(appRoutingActivity.connections)
        #expect(appRoutingActivity.appRoutingActivity)
        #expect(!appRoutingActivity.traffic)
        #expect(!appRoutingActivity.logs)
        #expect(!appRoutingActivity.proxies)
    }
}
