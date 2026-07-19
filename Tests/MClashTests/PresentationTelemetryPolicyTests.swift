import Testing
@testable import MClashApp

@Suite("Presentation telemetry policy")
struct PresentationTelemetryPolicyTests {
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
