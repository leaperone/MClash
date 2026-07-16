import AppKit

@MainActor
final class ApplicationDelegate: NSObject, NSApplicationDelegate {
    var shutdownHandler: (@MainActor () async -> Void)?
    private var terminationInProgress = false

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !terminationInProgress else { return .terminateLater }
        guard let shutdownHandler else { return .terminateNow }

        terminationInProgress = true
        Task {
            await shutdownHandler()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
