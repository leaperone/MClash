import AppKit

@MainActor
final class ApplicationDelegate: NSObject, NSApplicationDelegate {
    var shutdownHandler: (@MainActor () async -> Bool)?
    private var terminationInProgress = false

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !terminationInProgress else { return .terminateLater }
        guard let shutdownHandler else { return .terminateNow }

        terminationInProgress = true
        Task {
            let canTerminate = await shutdownHandler()
            terminationInProgress = false
            sender.reply(toApplicationShouldTerminate: canTerminate)
        }
        return .terminateLater
    }
}
