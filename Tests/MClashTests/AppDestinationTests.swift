@testable import MClashApp
import Testing

@Suite("Application destinations")
struct AppDestinationTests {
    @Test("App Routing has a stable persisted destination")
    func appRoutingDestination() {
        let destination = AppModel.Destination(rawValue: "appRouting")

        #expect(destination == .appRouting)
        #expect(destination?.title == "App Routing")
        #expect(destination?.symbol == "app.badge")
        #expect(AppModel.Destination.allCases.contains(.appRouting))
    }
}
