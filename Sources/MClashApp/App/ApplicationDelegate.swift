import AppKit

@MainActor
final class ApplicationDelegate: NSObject, NSApplicationDelegate {
    enum QuitChoice {
        case keepRunning
        case quitCompletely
        case cancel
    }

    struct TerminationContext {
        let coreIsConnected: Bool
        let appRoutingIsActive: Bool
        let systemProxyIsActive: Bool
    }

    var shutdownHandler: (@MainActor () async -> Bool)?
    var forceShutdownHandler: (@MainActor () async -> Void)?
    var willTerminateHandler: (@MainActor () -> Void)?
    var terminationContextProvider: (@MainActor () -> TerminationContext)?
    var quitChoiceHandler: (@MainActor () -> QuitChoice)?
    var keepRunningHandler: (@MainActor () -> Void)?
    private var terminationInProgress = false
    private var mainWindow: NSWindow?
    private var mainWindowObservers: [NSObjectProtocol] = []
    private var mainWindowVisibilityHandler: (@MainActor (Bool) -> Void)?
    private let instanceLock = ApplicationInstanceLock()
    private var applicationDidFinishLaunching = false
    private var applicationPreparationHandler: (@MainActor () async -> Void)?
    private var applicationPreparationTask: Task<Void, Never>?
    private var skipNextQuitConfirmation = false
    private var shouldPresentInitialMainWindow = ApplicationDelegate.initialWindowShouldPresent(
        arguments: CommandLine.arguments
    )

    override init() {
        super.init()
        if instanceLock.isOwner {
            DistributedNotificationCenter.default().addObserver(
                self,
                selector: #selector(activateExistingInstance(_:)),
                name: Self.activationRequestNotification,
                object: nil
            )
        }
    }

    deinit {
        DistributedNotificationCenter.default().removeObserver(self)
    }

    private static let activationRequestNotification = Notification.Name(
        "one.leaper.mclash.activate-existing-instance"
    )

    static func initialWindowShouldPresent(arguments: [String]) -> Bool {
        !arguments.contains("--mclash-background")
    }

    static func isLoginItemLaunch(event: NSAppleEventDescriptor?) -> Bool {
        event?.eventID == kAEOpenApplication
            && event?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue
                == keyAELaunchedAsLogInItem
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        if Self.isLoginItemLaunch(
            event: NSAppleEventManager.shared().currentAppleEvent
        ) {
            shouldPresentInitialMainWindow = false
        }

        guard instanceLock.isOwner else {
            if shouldPresentInitialMainWindow {
                DistributedNotificationCenter.default().postNotificationName(
                    Self.activationRequestNotification,
                    object: nil,
                    userInfo: nil,
                    deliverImmediately: true
                )
                activateRunningApplication()
            }
            NSApplication.shared.terminate(nil)
            return
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        applicationDidFinishLaunching = true
        startApplicationPreparationIfReady()
    }

    func registerApplicationPreparation(
        _ handler: @escaping @MainActor () async -> Void
    ) {
        guard applicationPreparationHandler == nil else { return }
        applicationPreparationHandler = handler
        startApplicationPreparationIfReady()
    }

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
            window.orderOut(nil)
            visibilityDidChange(mainWindowShouldMountPresentation)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(
        _ sender: NSApplication
    ) -> Bool {
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
        willTerminateHandler?()
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

        if !skipNextQuitConfirmation,
           !Self.isSystemTermination(
                event: NSAppleEventManager.shared().currentAppleEvent
           ) {
            switch quitChoiceHandler?() ?? quitChoiceAlert().runModal().runModalChoice {
            case .keepRunning:
                keepRunningInMenuBar(sender)
                return .terminateCancel
            case .cancel:
                return .terminateCancel
            case .quitCompletely:
                break
            }
        }
        skipNextQuitConfirmation = false

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
                    skipNextQuitConfirmation = false
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
        alert.messageText = AppLocalization.string("MClash Couldn’t Restore Network Settings")
        alert.informativeText = AppLocalization.string("macOS may still be configured to use MClash as its proxy. Quitting now may interrupt network access.")
        alert.addButton(withTitle: AppLocalization.string("Try Again"))
        alert.addButton(withTitle: AppLocalization.string("Cancel"))
        alert.addButton(withTitle: AppLocalization.string("Quit Anyway"))
        return alert
    }

    private func quitChoiceAlert() -> NSAlert {
        let context = terminationContextProvider?() ?? TerminationContext(
            coreIsConnected: false,
            appRoutingIsActive: false,
            systemProxyIsActive: false
        )
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = AppLocalization.string("Keep MClash Running in the Menu Bar?")

        var details = [
            AppLocalization.string(
                "Keep Running hides MClash windows while the menu bar item remains available."
            )
        ]
        if context.coreIsConnected {
            details.append(
                AppLocalization.string(
                    "Mihomo stays connected and continues providing local proxy service."
                )
            )
        }
        if context.appRoutingIsActive {
            details.append(
                AppLocalization.string("App Routing and DNS Routing remain active.")
            )
        }
        if context.systemProxyIsActive {
            details.append(
                AppLocalization.string(
                    "Quit Completely stops the proxy and safely restores the previous macOS System Proxy settings."
                )
            )
        } else {
            details.append(
                AppLocalization.string(
                    "Quit Completely stops MClash and its active networking services."
                )
            )
        }
        alert.informativeText = details.joined(separator: " ")

        alert.addButton(withTitle: AppLocalization.string("Keep Running"))
        let quitButton = alert.addButton(withTitle: AppLocalization.string("Quit Completely"))
        quitButton.hasDestructiveAction = true
        let cancelButton = alert.addButton(withTitle: AppLocalization.string("Cancel"))
        cancelButton.keyEquivalent = "\u{1b}"
        return alert
    }

    static func isSystemTermination(event: NSAppleEventDescriptor?) -> Bool {
        guard event?.eventID == kAEQuitApplication,
              let reason = event?.paramDescriptor(
                forKeyword: kAEQuitReason
              )?.enumCodeValue else { return false }
        return reason == kAEQuitAll
            || reason == kAEShutDown
            || reason == kAERestart
            || reason == kAEReallyLogOut
    }

    func prepareForUpdaterRelaunch() {
        skipNextQuitConfirmation = true
    }

    private func keepRunningInMenuBar(_ sender: NSApplication) {
        if let keepRunningHandler {
            keepRunningHandler()
            return
        }
        mainWindowVisibilityHandler?(false)
        sender.hide(nil)
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

    @objc
    private func activateExistingInstance(_ notification: Notification) {
        showMainWindow()
    }

    private func activateRunningApplication() {
        guard let bundleIdentifier = Bundle.main.bundleIdentifier else { return }
        let currentProcessIdentifier = ProcessInfo.processInfo.processIdentifier
        NSRunningApplication.runningApplications(
            withBundleIdentifier: bundleIdentifier
        )
        .first { $0.processIdentifier != currentProcessIdentifier }?
        .activate(options: [])
    }

    private func startApplicationPreparationIfReady() {
        guard instanceLock.isOwner,
              applicationDidFinishLaunching,
              applicationPreparationTask == nil,
              let applicationPreparationHandler else { return }
        applicationPreparationTask = Task {
            await applicationPreparationHandler()
        }
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

private extension NSApplication.ModalResponse {
    var runModalChoice: ApplicationDelegate.QuitChoice {
        switch self {
        case .alertFirstButtonReturn: .keepRunning
        case .alertSecondButtonReturn: .quitCompletely
        default: .cancel
        }
    }
}
