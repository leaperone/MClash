import SwiftUI

@main
struct MClashApp: App {
    @NSApplicationDelegateAdaptor(ApplicationDelegate.self) private var applicationDelegate
    @State private var model = AppModel()
    @State private var applicationUpdater = ApplicationUpdater()
    @State private var mainWindowContentIsActive = true

    var body: some Scene {
        Window("MClash", id: "main") {
            Group {
                if mainWindowContentIsActive {
                    ContentView(model: model, applicationUpdater: applicationUpdater)
                } else {
                    MainWindowDormantView()
                }
            }
                .frame(
                    minWidth: MClashLayout.mainWindowMinimumWidth,
                    minHeight: MClashLayout.mainWindowMinimumHeight
                )
                .background {
                    MainWindowRegistrationView { window in
                        applicationDelegate.registerMainWindow(window) { isVisible in
                            mainWindowContentIsActive = isVisible
                            model.setMainWindowVisible(isVisible)
                        }
                    }
                }
                .task {
                    await prepareApplication()
                }
                .onOpenURL { url in
                    applicationDelegate.showMainWindow()
                    Task { await model.handleIncomingURL(url) }
                }
        }
        .defaultSize(width: 1_180, height: 760)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") {
                    applicationUpdater.checkForUpdates()
                }
                .disabled(!applicationUpdater.canCheckForUpdates)
            }

            CommandGroup(replacing: .appSettings) {
                Button("Settings…") {
                    showSettings()
                }
                .keyboardShortcut(",", modifiers: .command)
            }
        }

        MenuBarExtra {
            MenuBarContent(model: model) { destination in
                showMainWindow(destination: destination)
            }
                .task { await prepareApplication() }
        } label: {
            MenuBarStatusLabel(model: model)
        }
        .menuBarExtraStyle(.window)

    }

    @MainActor
    private func showSettings() {
        showMainWindow(destination: .settings)
    }

    @MainActor
    private func showMainWindow(destination: AppModel.Destination) {
        model.selection = destination
        applicationDelegate.showMainWindow()
    }

    @MainActor
    private func prepareApplication() async {
        applicationDelegate.shutdownHandler = { [weak model] in
            guard let model else { return true }
            return await model.shutdown()
        }
        applicationDelegate.forceShutdownHandler = { [weak model] in
            await model?.forceShutdown()
        }
        await model.prepare()
    }
}

private struct MenuBarStatusLabel: View {
    @Bindable var model: AppModel

    var body: some View {
        Label(accessibilityLabel, systemImage: symbol)
    }

    private var symbol: String {
        if model.operationalIssues.contains(where: { $0.severity == .error }) {
            return "network.slash"
        }
        return switch model.coreState {
        case .running:
            model.controllerIsReady && configuredCaptureIsActive
                ? "network.badge.shield.half.filled"
                : "network"
        case .failed:
            "network.slash"
        case .validating, .starting, .stopping:
            "network"
        case .stopped:
            "network"
        }
    }

    private var configuredCaptureIsActive: Bool {
        if case .on = model.systemProxyState,
           model.systemProxyGuardFailure == nil {
            return true
        }
        if case .on = model.networkCaptureState {
            return true
        }
        return false
    }

    private var accessibilityLabel: String {
        if model.preparationInProgress {
            return "MClash, preparing application state"
        }
        if case let .failed(message) = model.systemProxyState {
            return "MClash, system proxy restoration failed: \(message)"
        }
        if case let .degraded(message) = model.controllerState {
            return "MClash, connected, controls unavailable: \(message)"
        }
        if model.isConnected, model.controllerIsReady, !model.systemProxyEnabled {
            return "MClash, core running, macOS System Proxy off"
        }
        return "MClash, \(model.statusTitle)"
    }
}

private struct MainWindowDormantView: View {
    var body: some View {
        Color.clear
            .accessibilityHidden(true)
    }
}

private struct MainWindowRegistrationView: NSViewRepresentable {
    let register: @MainActor (NSWindow) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        resolveWindow(from: view, coordinator: context.coordinator)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        resolveWindow(from: nsView, coordinator: context.coordinator)
    }

    private func resolveWindow(from view: NSView, coordinator: Coordinator) {
        guard coordinator.resolutionIsPending == false else { return }
        coordinator.resolutionIsPending = true
        DispatchQueue.main.async { [weak view, weak coordinator] in
            guard let coordinator else { return }
            coordinator.resolutionIsPending = false
            guard let window = view?.window,
                  coordinator.registeredWindow !== window else { return }
            coordinator.registeredWindow = window
            register(window)
        }
    }

    final class Coordinator {
        weak var registeredWindow: NSWindow?
        var resolutionIsPending = false
    }
}
