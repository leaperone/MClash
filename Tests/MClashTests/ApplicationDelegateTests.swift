import AppKit
import Testing
@testable import MClashApp

@Suite("Application lifecycle")
struct ApplicationDelegateTests {
    @MainActor
    @Test("Closing the main window unloads its content without terminating the app")
    func closeMainWindowDeactivatesPresentation() {
        let delegate = ApplicationDelegate()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        var visibilityChanges: [Bool] = []

        delegate.registerMainWindow(window) { visibilityChanges.append($0) }
        NotificationCenter.default.post(
            name: NSWindow.willCloseNotification,
            object: window
        )

        #expect(visibilityChanges.last == false)
        #expect(!delegate.applicationShouldTerminateAfterLastWindowClosed(.shared))
        #expect(!window.isReleasedWhenClosed)
    }

    @MainActor
    @Test("Closing another window does not unload the main presentation")
    func unrelatedWindowDoesNotDeactivatePresentation() {
        let delegate = ApplicationDelegate()
        let mainWindow = NSWindow()
        let otherWindow = NSWindow()
        var visibilityChanges: [Bool] = []

        delegate.registerMainWindow(mainWindow) { visibilityChanges.append($0) }
        visibilityChanges.removeAll()
        NotificationCenter.default.post(
            name: NSWindow.willCloseNotification,
            object: otherWindow
        )

        #expect(visibilityChanges.isEmpty)
    }

    @MainActor
    @Test("Minimizing or hiding the app suspends the main presentation")
    func minimizeAndHideDeactivatePresentation() {
        let delegate = ApplicationDelegate()
        let window = NSWindow()
        var visibilityChanges: [Bool] = []

        delegate.registerMainWindow(window) { visibilityChanges.append($0) }
        visibilityChanges.removeAll()
        NotificationCenter.default.post(
            name: NSWindow.didMiniaturizeNotification,
            object: window
        )
        delegate.applicationDidHide(
            Notification(name: NSApplication.didHideNotification)
        )

        #expect(visibilityChanges == [false, false])
    }
}
