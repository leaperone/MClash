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

        let suite = "ApplicationLifecycleTests.\(UUID().uuidString)"
        let defaults = try! #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(!ApplicationDelegate.initialWindowShouldPresent(
            arguments: ["MClash"],
            event: event,
            defaults: defaults
        ))
        defaults.set(false, forKey: AppModel.openAtLoginSilentlyKey)
        #expect(ApplicationDelegate.initialWindowShouldPresent(
            arguments: ["MClash"],
            event: event,
            defaults: defaults
        ))
    }

    @Test("Quiet login and lightweight mode persist across host restarts")
    @MainActor
    func startupModesPersist() throws {
        let suite = "ApplicationLifecycleTests.modes.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            suite,
            isDirectory: true
        )
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        let layout = ProfileDirectoryLayout(rootDirectory: root)

        let first = makeTestAppModel(
            profileDirectoryLayout: layout,
            preferenceDefaults: defaults
        )
        #expect(first.openAtLoginSilently)
        #expect(!first.lightweightMode)
        first.openAtLoginSilently = false
        first.lightweightMode = true

        let restored = makeTestAppModel(
            profileDirectoryLayout: layout,
            preferenceDefaults: defaults
        )
        #expect(!restored.openAtLoginSilently)
        #expect(restored.lightweightMode)
    }
}
