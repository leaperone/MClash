import AppKit

@MainActor
final class ApplicationDelegate: NSObject, NSApplicationDelegate {
    var shutdownHandler: (@MainActor () async -> Bool)?
    var forceShutdownHandler: (@MainActor () async -> Void)?
    private var terminationInProgress = false

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
}
