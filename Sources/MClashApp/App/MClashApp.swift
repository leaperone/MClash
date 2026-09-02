import SwiftUI

@main
struct MClashApp: App {
    @NSApplicationDelegateAdaptor(ApplicationDelegate.self) private var applicationDelegate
    @State private var model = AppModel()
    @State private var applicationUpdater = ApplicationUpdater()
    @State private var automationServer = AutomationSocketServer()
    @AppStorage(AppLanguage.storageKey) private var appLanguageRawValue = AppLanguage.system.rawValue
    @State private var mainWindowContentIsActive = ApplicationDelegate
        .initialWindowShouldPresent(
            arguments: CommandLine.arguments,
            event: NSAppleEventManager.shared().currentAppleEvent
        )

    var body: some Scene {
        // Quiet login and `mclashctl --mclash-background` do not instantiate
        // Window content. Core, Network Extension, and automation must start
        // from the scene graph itself.
        ApplicationBootstrapScene {
            applicationDelegate.registerApplicationPreparation {
                await prepareApplication()
            }
        } content: {
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
                            applicationDelegate.registerMainWindow(
                                window,
                                telemetryVisibilityDidChange: { isVisible in
                                    model.setMainWindowPresentationTelemetryVisible(isVisible)
                                }
                            ) { isVisible in
                                mainWindowContentIsActive = isVisible
                                model.setMainWindowVisible(isVisible)
                            }
                        }
                    }
                    .onOpenURL { url in
                        applicationDelegate.showMainWindow()
                        Task { await model.handleIncomingURL(url) }
                    }
                    .onChange(of: model.lightweightMode, initial: true) { _, isEnabled in
                        applicationDelegate.setLightweightMode(isEnabled)
                    }
            }
            .environment(\.locale, selectedLanguage.locale)
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
                navigationCommand("Configuration", destination: .workspaces, key: "2")
                navigationCommand("Rules", destination: .rules, key: "3")
                navigationCommand("Nodes", destination: .nodes, key: "4")
                navigationCommand("Sources", destination: .sources, key: "5")
                navigationCommand("Entrances", destination: .entrances, key: "6")
                navigationCommand("Node Groups", destination: .proxyGroups, key: "7")
                navigationCommand("Traffic", destination: .connections, key: "8")
            }

            CommandMenu("Routing") {
                Button(AppLocalization.string(model.isConnected ? "Disconnect" : "Connect")) {
                    Task { await model.toggleConnection() }
                }
                .keyboardShortcut("c", modifiers: [.command, .shift])
                .disabled(!model.canPerform(.connection) || (!model.isConnected && model.activeProfile == nil))

                Divider()

                Button(AppLocalization.string("Manage Rules…")) {
                    showMainWindow(destination: .rules)
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])

                Divider()

                routingModeCommand("Rule", mode: "rule", key: "1")
                routingModeCommand("Global", mode: "global", key: "2")
                routingModeCommand("Direct", mode: "direct", key: "3")
            }
        }

        MenuBarExtra(isInserted: lightweightMenuBarExtraIsInserted) {
            Button("Open MClash") {
                applicationDelegate.showMainWindow()
            }

            Divider()

            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        } label: {
            Image(systemName: "network")
                .symbolRenderingMode(.monochrome)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 16, height: 16)
                .accessibilityLabel("MClash")
        }
        .environment(\.locale, selectedLanguage.locale)
        .menuBarExtraStyle(.menu)

        MenuBarExtra(isInserted: standardMenuBarExtraIsInserted) {
            MenuBarContent(model: model) { destination in
                showMainWindow(destination: destination)
            }
        } label: {
            MenuBarStatusLabel(model: model)
        }
        .environment(\.locale, selectedLanguage.locale)
        .menuBarExtraStyle(.window)
        }
    }

    private var selectedLanguage: AppLanguage {
        AppLanguage(rawValue: appLanguageRawValue) ?? .system
    }

    private var lightweightMenuBarExtraIsInserted: Binding<Bool> {
        Binding(
            get: { model.lightweightMode },
            set: { _ in }
        )
    }

    private var standardMenuBarExtraIsInserted: Binding<Bool> {
        Binding(
            get: { !model.lightweightMode },
            set: { _ in }
        )
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
        _ title: LocalizedStringKey,
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
        _ title: LocalizedStringKey,
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
        do {
            try automationServer.start(
                model: model,
                updater: applicationUpdater
            ) { destination in
                showMainWindow(destination: destination)
            }
        } catch {
            model.errorMessage = AppLocalization.format(
                "External automation could not start: %@",
                error.localizedDescription
            )
        }
        await model.prepare()
    }
}

private struct ApplicationBootstrapScene<Content: Scene>: Scene {
    private let content: Content

    init(
        register: () -> Void,
        @SceneBuilder content: () -> Content
    ) {
        register()
        self.content = content()
    }

    var body: some Scene {
        content
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
            if model.lightweightMode {
                Image(systemName: symbol)
                    .symbolRenderingMode(.monochrome)
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 16, height: 16)
                    .accessibilityLabel(accessibilityLabel)
            } else {
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
            return AppLocalization.string("MClash, preparing application state")
        }
        if case let .failed(message) = model.systemProxyState {
            return AppLocalization.format(
                "MClash, system proxy restoration failed: %@",
                message
            )
        }
        if case let .degraded(message) = model.controllerState {
            return AppLocalization.format(
                "MClash, connected, controls unavailable: %@",
                message
            )
        }
        if model.isConnected, model.controllerIsReady, !model.systemProxyEnabled {
            return AppLocalization.string("MClash, core running, macOS System Proxy off")
        }
        return AppLocalization.format(
            "MClash, %@",
            coreStatusTitle
        )
    }

    private var coreStatusTitle: String {
        let key = switch model.coreState {
        case .stopped: "Not Connected"
        case .validating: "Checking"
        case .starting: "Starting"
        case .running: "Connected"
        case .stopping: "Stopping"
        case .failed: "Failed"
        }
        return AppLocalization.string(key)
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
