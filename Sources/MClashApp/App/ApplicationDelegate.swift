import AppKit

@MainActor
final class ApplicationDelegate: NSObject, NSApplicationDelegate {
    var shutdownHandler: (@MainActor () async -> Bool)?
    var forceShutdownHandler: (@MainActor () async -> Void)?
    private var terminationInProgress = false
    private var mainWindow: NSWindow?
    private var shouldPresentInitialMainWindow = true

    func registerMainWindow(_ window: NSWindow) {
        window.identifier = NSUserInterfaceItemIdentifier("MClash.MainWindow")
        window.contentMinSize = NSSize(
            width: MClashLayout.mainWindowMinimumWidth,
            height: MClashLayout.mainWindowMinimumHeight
        )
        mainWindow = window
        guard shouldPresentInitialMainWindow else { return }
        shouldPresentInitialMainWindow = false
        showMainWindow()
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        showMainWindow()
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !terminationInProgress else { return .terminateLater }
        guard let shutdownHandler else { return .terminateNow }

        terminationInProgress = true
        Task {
            while true {
                if await shutdownHandler() {
                    terminationInProgress = false
                    sender.reply(toApplicationShouldTerminate: true)
                    return
                }

                sender.activate(ignoringOtherApps: true)
                let response = terminationFailureAlert().runModal()
                switch response {
                case .alertFirstButtonReturn:
                    continue
                case .alertThirdButtonReturn:
                    await forceShutdownHandler?()
                    terminationInProgress = false
                    sender.reply(toApplicationShouldTerminate: true)
                    return
                default:
                    terminationInProgress = false
                    sender.reply(toApplicationShouldTerminate: false)
                    return
                }
            }
        }
        return .terminateLater
    }

    private func terminationFailureAlert() -> NSAlert {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "MClash Couldn’t Restore Network Settings"
        alert.informativeText = "macOS may still be configured to use MClash as its proxy. Quitting now may interrupt network access."
        alert.addButton(withTitle: "Try Again")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Quit Anyway")
        return alert
    }

    func showMainWindow() {
        guard let mainWindow else {
            shouldPresentInitialMainWindow = true
            return
        }
        mainWindow.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
}
