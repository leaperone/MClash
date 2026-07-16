import SwiftUI

@main
struct MClashApp: App {
    @NSApplicationDelegateAdaptor(ApplicationDelegate.self) private var applicationDelegate
    @State private var model = AppModel()

    var body: some Scene {
        Window("MClash", id: "main") {
            ContentView(model: model)
                .frame(minWidth: 780, minHeight: 560)
                .background {
                    MainWindowRegistrationView { window in
                        applicationDelegate.registerMainWindow(window)
                    }
                }
                .task {
                    await prepareApplication()
                }
        }
        .defaultSize(width: 1_180, height: 760)

        MenuBarExtra {
            MenuBarContent(model: model)
                .task { await prepareApplication() }
        } label: {
            Label(menuBarAccessibilityLabel, systemImage: menuBarSymbol)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(model: model)
                .frame(width: 560, height: 460)
        }
    }

    private var menuBarSymbol: String {
        if case .failed = model.systemProxyState {
            return "network.slash"
        }
        return switch model.coreState {
        case .running:
            model.controllerIsReady ? "network.badge.shield.half.filled" : "network"
        case .failed:
            "network.slash"
        case .validating, .starting, .stopping:
            "network"
        case .stopped:
            "network"
        }
    }

    private var menuBarAccessibilityLabel: String {
        if model.preparationInProgress {
            return "MClash, preparing application state"
        }
        if case let .failed(message) = model.systemProxyState {
            return "MClash, system proxy restoration failed: \(message)"
        }
        if case let .degraded(message) = model.controllerState {
            return "MClash, connected, controls unavailable: \(message)"
        }
        if model.liveMetricsAreDegraded {
            return "MClash, connected, live metrics reconnecting"
        }
        return "MClash, \(model.statusTitle)"
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

private struct MainWindowRegistrationView: NSViewRepresentable {
    let register: @MainActor (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        resolveWindow(from: view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        resolveWindow(from: nsView)
    }

    private func resolveWindow(from view: NSView) {
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            register(window)
        }
    }
}
