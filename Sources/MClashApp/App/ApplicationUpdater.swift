import Foundation
import Observation
import Sparkle

/// Owns Sparkle's standard update UI and exposes its persisted user settings to SwiftUI.
///
/// Sparkle initiates relaunch by terminating the application. That termination still flows
/// through `ApplicationDelegate.applicationShouldTerminate`, so MClash restores the user's
/// system proxy and stops mihomo before Sparkle replaces and relaunches the app bundle.
@MainActor
@Observable
final class ApplicationUpdater {
    private(set) var canCheckForUpdates = false
    private(set) var automaticallyChecksForUpdates = false
    private(set) var automaticallyDownloadsUpdates = false
    private(set) var allowsAutomaticUpdates = false

    @ObservationIgnored
    private let controller: SPUStandardUpdaterController
    @ObservationIgnored
    private let updaterDelegate: ApplicationUpdaterDelegate
    @ObservationIgnored
    private var observations: [NSKeyValueObservation] = []

    init(startingUpdater: Bool = true) {
        let updaterDelegate = ApplicationUpdaterDelegate()
        self.updaterDelegate = updaterDelegate
        controller = SPUStandardUpdaterController(
            startingUpdater: startingUpdater,
            updaterDelegate: updaterDelegate,
            userDriverDelegate: nil
        )
        observeUpdaterSettings()
        refreshSnapshot()
    }

    var willRelaunchApplication: (@MainActor () -> Void)? {
        get { updaterDelegate.willRelaunchApplication }
        set { updaterDelegate.willRelaunchApplication = newValue }
    }

    func checkForUpdates() {
        guard canCheckForUpdates else { return }
        controller.checkForUpdates(nil)
    }

    func setAutomaticallyChecksForUpdates(_ enabled: Bool) {
        controller.updater.automaticallyChecksForUpdates = enabled
        refreshSnapshot()
    }

    func setAutomaticallyDownloadsUpdates(_ enabled: Bool) {
        guard controller.updater.allowsAutomaticUpdates else { return }
        controller.updater.automaticallyDownloadsUpdates = enabled
        refreshSnapshot()
    }

    private func observeUpdaterSettings() {
        let updater = controller.updater
        observations = [
            updater.observe(\.canCheckForUpdates, options: [.initial, .new]) {
                [weak self] _, _ in
                Task { @MainActor [weak self] in self?.refreshSnapshot() }
            },
            updater.observe(\.automaticallyChecksForUpdates, options: [.initial, .new]) {
                [weak self] _, _ in
                Task { @MainActor [weak self] in self?.refreshSnapshot() }
            },
            updater.observe(\.automaticallyDownloadsUpdates, options: [.initial, .new]) {
                [weak self] _, _ in
                Task { @MainActor [weak self] in self?.refreshSnapshot() }
            },
            updater.observe(\.allowsAutomaticUpdates, options: [.initial, .new]) {
                [weak self] _, _ in
                Task { @MainActor [weak self] in self?.refreshSnapshot() }
            },
        ]
    }

    private func refreshSnapshot() {
        let updater = controller.updater
        canCheckForUpdates = updater.canCheckForUpdates
        automaticallyChecksForUpdates = updater.automaticallyChecksForUpdates
        automaticallyDownloadsUpdates = updater.automaticallyDownloadsUpdates
        allowsAutomaticUpdates = updater.allowsAutomaticUpdates
    }
}

@MainActor
private final class ApplicationUpdaterDelegate: NSObject, SPUUpdaterDelegate {
    var willRelaunchApplication: (@MainActor () -> Void)?

    func updaterWillRelaunchApplication(_ updater: SPUUpdater) {
        willRelaunchApplication?()
    }
}
