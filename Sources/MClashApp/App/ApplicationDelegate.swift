import AppKit

@MainActor
final class ApplicationDelegate: NSObject, NSApplicationDelegate {
    var shutdownHandler: (@MainActor () async -> Bool)?
    var forceShutdownHandler: (@MainActor () async -> Void)?
    private var terminationInProgress = false
    private var mainWindow: NSWindow?
    private var mainWindowObservers: [NSObjectProtocol] = []
    private var mainWindowVisibilityHandler: (@MainActor (Bool) -> Void)?
    private var shouldPresentInitialMainWindow = true

    func registerMainWindow(
        _ window: NSWindow,
        visibilityDidChange: @escaping @MainActor (Bool) -> Void
    ) {
        mainWindowVisibilityHandler = visibilityDidChange
        guard mainWindow !== window else { return }

        removeMainWindowObservers()
        window.identifier = NSUserInterfaceItemIdentifier("MClash.MainWindow")
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(
            width: MClashLayout.mainWindowMinimumWidth,
            height: MClashLayout.mainWindowMinimumHeight
        )
        mainWindow = window
        observeMainWindow(window)
        if shouldPresentInitialMainWindow {
            shouldPresentInitialMainWindow = false
            showMainWindow()
        } else {
            visibilityDidChange(mainWindowShouldMountPresentation)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(
        _ sender: NSApplication
    ) -> Bool {
        false
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        showMainWindow()
        return true
    }

    func applicationDidHide(_ notification: Notification) {
        mainWindowVisibilityHandler?(false)
    }

    func applicationDidUnhide(_ notification: Notification) {
        mainWindowVisibilityHandler?(mainWindowShouldMountPresentation)
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
        mainWindowVisibilityHandler?(true)
        mainWindow.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    private func observeMainWindow(_ window: NSWindow) {
        let center = NotificationCenter.default
        mainWindowObservers.append(
            center.addObserver(
                forName: NSWindow.willCloseNotification,
                object: window,
                queue: .main
            ) { [weak self, weak window] _ in
                MainActor.assumeIsolated {
                    guard let self, self.mainWindow === window else { return }
                    self.mainWindowVisibilityHandler?(false)
                }
            }
        )
        mainWindowObservers.append(
            center.addObserver(
                forName: NSWindow.didMiniaturizeNotification,
                object: window,
                queue: .main
            ) { [weak self, weak window] _ in
                MainActor.assumeIsolated {
                    guard let self, self.mainWindow === window else { return }
                    self.mainWindowVisibilityHandler?(false)
                }
            }
        )
        mainWindowObservers.append(
            center.addObserver(
                forName: NSWindow.didDeminiaturizeNotification,
                object: window,
                queue: .main
            ) { [weak self, weak window] _ in
                MainActor.assumeIsolated {
                    guard let self, self.mainWindow === window else { return }
                    self.mainWindowVisibilityHandler?(
                        self.mainWindowShouldMountPresentation
                    )
                }
            }
        )
    }

    private var mainWindowShouldMountPresentation: Bool {
        guard let mainWindow else { return false }
        return mainWindow.isVisible
            && !mainWindow.isMiniaturized
            && !NSApplication.shared.isHidden
    }

    private func removeMainWindowObservers() {
        let center = NotificationCenter.default
        mainWindowObservers.forEach(center.removeObserver)
        mainWindowObservers.removeAll()
    }
}
