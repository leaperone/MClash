import SwiftUI

@main
struct MClashApp: App {
    @NSApplicationDelegateAdaptor(ApplicationDelegate.self) private var applicationDelegate
    @State private var model = AppModel()
    @State private var applicationUpdater = ApplicationUpdater()
    @State private var automationServer = AutomationSocketServer()
    @State private var mainWindowContentIsActive = ApplicationDelegate
        .initialWindowShouldPresent(arguments: CommandLine.arguments)

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
                .background {
                    ApplicationLifecycleRegistrationView {
                        applicationDelegate.registerApplicationPreparation {
                            await prepareApplication()
                        }
                    }
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

            CommandMenu("Navigate") {
                navigationCommand("Overview", destination: .overview, key: "1")
                navigationCommand("Traffic", destination: .connections, key: "2")
                navigationCommand("Proxies", destination: .proxies, key: "3")
                navigationCommand("App Routing", destination: .appRouting, key: "4")
                navigationCommand("Profiles", destination: .profiles, key: "5")
            }

            CommandMenu("Routing") {
                Button(model.isConnected ? "Disconnect" : "Connect") {
                    Task { await model.toggleConnection() }
                }
                .keyboardShortcut("c", modifiers: [.command, .shift])
                .disabled(!model.canPerform(.connection) || (!model.isConnected && model.activeProfile == nil))

                Divider()

                routingModeCommand("Rule", mode: "rule", key: "1")
                routingModeCommand("Global", mode: "global", key: "2")
                routingModeCommand("Direct", mode: "direct", key: "3")
            }
        }

        MenuBarExtra {
            MenuBarContent(model: model) { destination in
                showMainWindow(destination: destination)
            }
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
    private func navigationCommand(
        _ title: String,
        destination: AppModel.Destination,
        key: KeyEquivalent
    ) -> some View {
        Button(title) {
            showMainWindow(destination: destination)
        }
        .keyboardShortcut(key, modifiers: .command)
    }

    @MainActor
    private func routingModeCommand(
        _ title: String,
        mode: String,
        key: KeyEquivalent
    ) -> some View {
        Button(title) {
            Task { await model.setMode(mode) }
        }
        .keyboardShortcut(key, modifiers: [.command, .option])
        .disabled(
            !model.isConnected
                || !model.controllerIsReady
                || !model.canPerform(.changeMode)
                || (model.pendingMode ?? model.runtimeConfig?.mode)?.lowercased() == mode
        )
    }

    @MainActor
    private func prepareApplication() async {
        applicationUpdater.willRelaunchApplication = { [weak applicationDelegate] in
            applicationDelegate?.prepareForUpdaterRelaunch()
        }
        applicationDelegate.shutdownHandler = { [weak model] in
            guard let model else { return true }
            return await model.shutdown()
        }
        applicationDelegate.forceShutdownHandler = { [weak model] in
            await model?.forceShutdown()
        }
        applicationDelegate.terminationContextProvider = { [weak model] in
            guard let model else {
                return ApplicationDelegate.TerminationContext(
                    coreIsConnected: false,
                    appRoutingIsActive: false,
                    systemProxyIsActive: false
                )
            }
            let appRoutingIsActive: Bool
            if case .on = model.networkCaptureState {
                appRoutingIsActive = true
            } else {
                appRoutingIsActive = false
            }
            return ApplicationDelegate.TerminationContext(
                coreIsConnected: model.isConnected,
                appRoutingIsActive: appRoutingIsActive,
                systemProxyIsActive: model.systemProxyEnabled
            )
        }
        applicationDelegate.willTerminateHandler = { [automationServer] in
            automationServer.stop()
        }
        await model.prepare()
        do {
            try automationServer.start(
                model: model,
                updater: applicationUpdater
            ) { destination in
                showMainWindow(destination: destination)
            }
        } catch {
            model.errorMessage = "External automation could not start: \(error.localizedDescription)"
        }
    }
}

private struct ApplicationLifecycleRegistrationView: NSViewRepresentable {
    let register: @MainActor () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        registerIfNeeded(context.coordinator)
        return NSView(frame: .zero)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        registerIfNeeded(context.coordinator)
    }

    private func registerIfNeeded(_ coordinator: Coordinator) {
        guard !coordinator.didRegister else { return }
        coordinator.didRegister = true
        register()
    }

    final class Coordinator {
        var didRegister = false
    }
}

private struct MenuBarStatusLabel: View {
    @Bindable var model: AppModel

    @ViewBuilder
    var body: some View {
        switch model.menuBarDisplayStyle {
        case .logo:
            Image(systemName: symbol)
                .symbolRenderingMode(.monochrome)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 16, height: 16)
                .accessibilityLabel(accessibilityLabel)
        case .proxyStatus:
            HStack(spacing: 3) {
                menuBarMetric(
                    symbol: "arrow.down",
                    value: menuBarRate(model.traffic.download),
                    valueWidth: 27
                )
                menuBarMetric(
                    symbol: "arrow.up",
                    value: menuBarRate(model.traffic.upload),
                    valueWidth: 27
                )
                menuBarMetric(
                    symbol: "arrow.left.arrow.right",
                    value: menuBarConnectionCount,
                    valueWidth: 24
                )
            }
            .frame(width: 114, alignment: .leading)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityLabel)
        }
    }

    private func menuBarMetric(
        symbol: String,
        value: String,
        valueWidth: CGFloat
    ) -> some View {
        HStack(spacing: 1) {
            Image(systemName: symbol)
                .font(.system(size: 8, weight: .medium))
                .frame(width: 9)
            Text(value)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .lineLimit(1)
                .frame(width: valueWidth, alignment: .trailing)
        }
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

    private func menuBarRate(_ value: Int64) -> String {
        guard model.liveStreamHealth[.traffic]?.phase == .live else { return "—" }
        return compactMenuBarByteRate(value)
    }

    private var menuBarConnectionCount: String {
        guard model.liveStreamHealth[.connections]?.phase == .live else { return "—" }
        return compactMenuBarCount(model.connections?.connections.count ?? 0)
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
