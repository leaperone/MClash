@testable import MClashApp
import AppKit
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

    @Test("A main-app login item launch is recognized as background startup")
    @MainActor
    func loginItemAppleEventIsRecognized() {
        let event = NSAppleEventDescriptor(
            eventClass: AEEventClass(kCoreEventClass),
            eventID: AEEventID(kAEOpenApplication),
            targetDescriptor: nil,
            returnID: AEReturnID(kAutoGenerateReturnID),
            transactionID: AETransactionID(kAnyTransactionID)
        )
        event.setParam(
            NSAppleEventDescriptor(enumCode: keyAELaunchedAsLogInItem),
            forKeyword: keyAEPropData
        )

        #expect(ApplicationDelegate.isLoginItemLaunch(event: event))
        #expect(ApplicationDelegate.isLoginItemLaunch(event: nil) == false)
    }
}
