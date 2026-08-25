import AppKit
import Testing
@testable import MClashApp

@Suite("Application lifecycle")
struct ApplicationDelegateTests {
    @Test("Lightweight mode hides the Dock only while the main window is dormant")
    @MainActor
    func lightweightActivationPolicy() {
        #expect(ApplicationDelegate.activationPolicy(
            lightweightMode: true,
            mainWindowVisible: false
        ) == .accessory)
        #expect(ApplicationDelegate.activationPolicy(
            lightweightMode: true,
            mainWindowVisible: true
        ) == .regular)
        #expect(ApplicationDelegate.activationPolicy(
            lightweightMode: false,
            mainWindowVisible: false
        ) == .regular)
    }

    @Test("Lightweight mode hides visible UI and ignores later occlusion changes")
    @MainActor
    func lightweightOcclusionPolicy() {
        #expect(!ApplicationDelegate.shouldRunMainWindowPresentationTelemetry(
            lightweightMode: true,
            mainWindowIsVisible: true,
            windowOcclusionState: []
        ))
        #expect(ApplicationDelegate.shouldRunMainWindowPresentationTelemetry(
            lightweightMode: true,
            mainWindowIsVisible: true,
            windowOcclusionState: .visible
        ))
        #expect(ApplicationDelegate.shouldRunMainWindowPresentationTelemetry(
            lightweightMode: false,
            mainWindowIsVisible: true,
            windowOcclusionState: []
        ))
        #expect(!ApplicationDelegate.shouldRunMainWindowPresentationTelemetry(
            lightweightMode: false,
            mainWindowIsVisible: false,
            windowOcclusionState: .visible
        ))

        let delegate = ApplicationDelegate()
        let window = NSWindow()
        var contentVisibilityChanges: [Bool] = []
        var telemetryVisibilityChanges: [Bool] = []
        delegate.registerMainWindow(
            window,
            telemetryVisibilityDidChange: {
                telemetryVisibilityChanges.append($0)
            }
        ) {
            contentVisibilityChanges.append($0)
        }
        contentVisibilityChanges.removeAll()
        telemetryVisibilityChanges.removeAll()
        delegate.setLightweightMode(true)
        #expect(contentVisibilityChanges == [false])
        contentVisibilityChanges.removeAll()
        telemetryVisibilityChanges.removeAll()

        NotificationCenter.default.post(
            name: NSWindow.didChangeOcclusionStateNotification,
            object: window
        )

        #expect(contentVisibilityChanges.isEmpty)
        #expect(telemetryVisibilityChanges.last == false)
    }

    @Test("Login-item launches are quiet by default and remain configurable")
    @MainActor
    func loginItemQuietPreference() throws {
        let suite = "ApplicationDelegateTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        #expect(ApplicationDelegate.opensQuietlyAtLogin(defaults: defaults))
        defaults.set(false, forKey: AppModel.openAtLoginSilentlyKey)
        #expect(!ApplicationDelegate.opensQuietlyAtLogin(defaults: defaults))
    }

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

    @MainActor
    @Test("Quitting can keep the proxy running in the menu bar")
    func quitCanBecomeBackgroundOperation() {
        let delegate = ApplicationDelegate()
        var shutdownWasRequested = false
        var keptRunning = false
        delegate.shutdownHandler = {
            shutdownWasRequested = true
            return true
        }
        delegate.quitChoiceHandler = { .keepRunning }
        delegate.keepRunningHandler = { keptRunning = true }

        let response = delegate.applicationShouldTerminate(.shared)

        #expect(response == .terminateCancel)
        #expect(keptRunning)
        #expect(!shutdownWasRequested)
    }

    @MainActor
    @Test("Sparkle relaunch bypasses the interactive quit choice")
    func updaterRelaunchSkipsQuitChoice() {
        let delegate = ApplicationDelegate()
        var quitChoiceWasRequested = false
        delegate.shutdownHandler = { true }
        delegate.quitChoiceHandler = {
            quitChoiceWasRequested = true
            return .cancel
        }

        delegate.prepareForUpdaterRelaunch()
        let response = delegate.applicationShouldTerminate(.shared)

        #expect(response == .terminateLater)
        #expect(!quitChoiceWasRequested)
    }
}
