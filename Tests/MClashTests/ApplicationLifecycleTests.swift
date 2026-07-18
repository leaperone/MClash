@testable import MClashApp
import Testing

@Suite("Application lifecycle")
struct ApplicationLifecycleTests {
    @Test("Automation launch keeps the initial main window dormant")
    @MainActor
    func backgroundLaunchDoesNotPresentMainWindow() {
        #expect(ApplicationDelegate.initialWindowShouldPresent(
            arguments: ["MClash", "--mclash-background"]
        ) == false)
        #expect(ApplicationDelegate.initialWindowShouldPresent(
            arguments: ["MClash"]
        ) == true)
    }
}
