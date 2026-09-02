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
    private var mainWindowTelemetryVisibilityHandler: (@MainActor (Bool) -> Void)?
    private var mainWindowPresentationIsVisible = false
    private let instanceLock = ApplicationInstanceLock()
    private var applicationDidFinishLaunching = false
    private var applicationPreparationHandler: (@MainActor () async -> Void)?
    private var applicationPreparationTask: Task<Void, Never>?
    private var skipNextQuitConfirmation = false
    private var lightweightModeEnabled = UserDefaults.standard.bool(
        forKey: AppModel.lightweightModeKey
    )
    private var shouldPresentInitialMainWindow = ApplicationDelegate.initialWindowShouldPresent(
        arguments: CommandLine.arguments,
        event: NSAppleEventManager.shared().currentAppleEvent
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

    static func initialWindowShouldPresent(
        arguments: [String],
        event: NSAppleEventDescriptor? = nil,
        defaults: UserDefaults = .standard
    ) -> Bool {
        launchRequestsPresentation(
            arguments: arguments,
            event: event,
            defaults: defaults
        ) && !defaults.bool(forKey: AppModel.lightweightModeKey)
    }

    private static func launchRequestsPresentation(
        arguments: [String],
        event: NSAppleEventDescriptor? = nil,
        defaults: UserDefaults = .standard
    ) -> Bool {
        guard !arguments.contains("--mclash-background") else { return false }
        return !isLoginItemLaunch(event: event)
            || !opensQuietlyAtLogin(defaults: defaults)
    }

    static func isLoginItemLaunch(event: NSAppleEventDescriptor?) -> Bool {
        event?.eventID == kAEOpenApplication
            && event?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue
                == keyAELaunchedAsLogInItem
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        updateActivationPolicy()
        if Self.isLoginItemLaunch(
            event: NSAppleEventManager.shared().currentAppleEvent
        ), Self.opensQuietlyAtLogin() {
            shouldPresentInitialMainWindow = false
        }

        guard instanceLock.isOwner else {
            if Self.launchRequestsPresentation(
                arguments: CommandLine.arguments,
                event: NSAppleEventManager.shared().currentAppleEvent
            ) {
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

    /// Scene-graph registration, not Window content. Quiet login and
    /// `--mclash-background` never instantiate the main window view tree.
    func registerApplicationPreparation(
        _ handler: @escaping @MainActor () async -> Void
    ) {
        guard applicationPreparationHandler == nil else { return }
        applicationPreparationHandler = handler
        startApplicationPreparationIfReady()
    }

    func registerMainWindow(
        _ window: NSWindow,
        telemetryVisibilityDidChange: (@MainActor (Bool) -> Void)? = nil,
        visibilityDidChange: @escaping @MainActor (Bool) -> Void
    ) {
        mainWindowVisibilityHandler = visibilityDidChange
        mainWindowTelemetryVisibilityHandler = telemetryVisibilityDidChange
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
            publishMainWindowVisibility(false)
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
        publishMainWindowVisibility(false)
    }

    func applicationDidUnhide(_ notification: Notification) {
        publishMainWindowVisibility(mainWindowShouldMountPresentation)
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

    static func opensQuietlyAtLogin(defaults: UserDefaults = .standard) -> Bool {
        if defaults.object(forKey: AppModel.openAtLoginSilentlyKey) == nil {
            return true
        }
        return defaults.bool(forKey: AppModel.openAtLoginSilentlyKey)
    }

    func prepareForUpdaterRelaunch() {
        skipNextQuitConfirmation = true
    }

    func setLightweightMode(_ isEnabled: Bool) {
        lightweightModeEnabled = isEnabled
        if isEnabled, mainWindowPresentationIsVisible {
            mainWindow?.orderOut(nil)
            publishMainWindowVisibility(false)
            return
        }
        publishMainWindowTelemetryVisibility(
            mainWindowShouldRunPresentationTelemetry
        )
        updateActivationPolicy()
    }

    static func activationPolicy(
        lightweightMode: Bool,
        mainWindowVisible: Bool
    ) -> NSApplication.ActivationPolicy {
        lightweightMode && !mainWindowVisible ? .accessory : .regular
    }

    static func shouldRunMainWindowPresentationTelemetry(
        lightweightMode: Bool,
        mainWindowIsVisible: Bool,
        windowOcclusionState: NSWindow.OcclusionState
    ) -> Bool {
        guard mainWindowIsVisible else { return false }
        return !lightweightMode || windowOcclusionState.contains(.visible)
    }

    private func keepRunningInMenuBar(_ sender: NSApplication) {
        if let keepRunningHandler {
            keepRunningHandler()
            return
        }
        publishMainWindowVisibility(false)
        sender.hide(nil)
    }

    func showMainWindow() {
        guard let mainWindow else {
            shouldPresentInitialMainWindow = true
            return
        }
        publishMainWindowVisibility(true)
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
                    self.publishMainWindowVisibility(false)
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
                    self.publishMainWindowVisibility(false)
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
                    self.publishMainWindowVisibility(
                        self.mainWindowShouldMountPresentation
                    )
                }
            }
        )
        mainWindowObservers.append(
            center.addObserver(
                forName: NSWindow.didChangeOcclusionStateNotification,
                object: window,
                queue: .main
            ) { [weak self, weak window] _ in
                MainActor.assumeIsolated {
                    guard let self, self.mainWindow === window else { return }
                    self.publishMainWindowTelemetryVisibility(
                        self.mainWindowShouldRunPresentationTelemetry
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

    private var mainWindowShouldRunPresentationTelemetry: Bool {
        guard let mainWindow else { return false }
        return Self.shouldRunMainWindowPresentationTelemetry(
            lightweightMode: lightweightModeEnabled,
            mainWindowIsVisible: mainWindowPresentationIsVisible,
            windowOcclusionState: mainWindow.occlusionState
        )
    }

    private func updateActivationPolicy() {
        NSApplication.shared.setActivationPolicy(
            Self.activationPolicy(
                lightweightMode: lightweightModeEnabled,
                mainWindowVisible: mainWindowPresentationIsVisible
            )
        )
    }

    private func publishMainWindowVisibility(_ isVisible: Bool) {
        mainWindowPresentationIsVisible = isVisible
        mainWindowVisibilityHandler?(isVisible)
        publishMainWindowTelemetryVisibility(
            mainWindowShouldRunPresentationTelemetry
        )
        updateActivationPolicy()
    }

    private func publishMainWindowTelemetryVisibility(_ isVisible: Bool) {
        mainWindowTelemetryVisibilityHandler?(isVisible)
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
