import AppKit
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @Bindable var model: AppModel
    @Bindable var applicationUpdater: ApplicationUpdater
    @State private var advancedSettingsExpanded = false
    @State private var coreDetailsExpanded = false
    @State private var showingListenerPortSettings = false
    @State private var showingProfileRouteListenerSettings = false
    @State private var showingRuntimeSettings = false
    @State private var showingSystemProxySettings = false
    @State private var applicationSettingsError: String?
    @State private var commandLineToolStatus = CommandLineToolInstaller.Status.notInstalled
    @State private var commandLineToolError: String?
    @AppStorage(AppLanguage.storageKey) private var appLanguageRawValue = AppLanguage.system.rawValue

    var body: some View {
        Form {
            Section("General") {
                Picker("Language", selection: $appLanguageRawValue) {
                    ForEach(AppLanguage.allCases) { language in
                        if language == .system {
                            Text("System Default")
                                .tag(language.rawValue)
                        } else {
                            Text(verbatim: language.displayName)
                                .tag(language.rawValue)
                        }
                    }
                }
                .pickerStyle(.menu)

                Toggle("Open MClash at login", isOn: launchAtLoginBinding)
                if model.launchAtLogin {
                    Toggle("Open quietly at login", isOn: $model.openAtLoginSilently)
                }
                if model.launchAtLoginRequiresApproval {
                    HStack {
                        Label("macOS approval is required before MClash can open at login.", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                        Spacer()
                        Button("Open Login Items") {
                            SMAppService.openSystemSettingsLoginItems()
                        }
                    }
                }
                Toggle("Restore the last connected session when MClash opens", isOn: $model.autoConnectOnLaunch)
                Toggle("Lightweight mode", isOn: $model.lightweightMode)
                if model.lightweightMode {
                    Text("When hidden, MClash pauses live interface updates while proxying and recovery stay active.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    DisclosureGroup("Menu Bar") {
                        Toggle(
                            "Show proxy status in the menu bar",
                            isOn: Binding(
                                get: { model.menuBarDisplayStyle == .proxyStatus },
                                set: { enabled in
                                    model.menuBarDisplayStyle = enabled ? .proxyStatus : .logo
                                }
                            )
                        )
                        Text("Turn this off to use the quieter network icon.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section("Advanced connection behavior") {
                Text(AppLocalization.string("Connection paths and their on/off controls are managed together on the How to Connect page."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button(AppLocalization.string("Open Entrances…")) {
                    model.selection = .entrances
                }
                DisclosureGroup("Connection Behavior") {
                    Toggle("Enable macOS system proxy when connecting", isOn: $model.autoEnableSystemProxy)
                        .disabled(model.networkCapturePreferences.enabled)
                    if model.networkCapturePreferences.enabled {
                        Text("App Routing takes precedence over the macOS System Proxy.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Toggle(
                        "Close existing connections after changing mode or node",
                        isOn: $model.closeConnectionsOnRoutingChange
                    )

                    if let verifiedAt = model.systemProxyGuardLastVerifiedAt {
                        LabeledContent(
                            "Last macOS verification",
                            value: AppLocalization.relativeDate(verifiedAt)
                        )
                        .help(
                            verifiedAt.formatted(
                                .dateTime
                                    .year()
                                    .month(.abbreviated)
                                    .day()
                                    .hour()
                                    .minute()
                                    .second()
                                    .locale(AppLocalization.selectedLocale)
                            )
                        )
                    }
                    if let verifiedAt = model.appRoutingProviderLastVerifiedAt {
                        LabeledContent(
                            "App Routing provider verified",
                            value: AppLocalization.relativeDate(verifiedAt)
                        )
                        .help(
                            verifiedAt.formatted(
                                .dateTime
                                    .year()
                                    .month(.abbreviated)
                                    .day()
                                    .hour()
                                    .minute()
                                    .second()
                                    .locale(AppLocalization.selectedLocale)
                            )
                        )
                    }
                    if model.systemProxyEnabled {
                        LabeledContent(
                            "Proxy Guard",
                            value: AppLocalization.string(
                                model.systemProxyPreferences.guardEnabled ? "Active" : "Paused"
                            )
                        )
                        if let repairedAt = model.systemProxyGuardLastRepairedAt {
                            LabeledContent(
                                "External changes repaired",
                                value: AppLocalization.format(
                                    "%d · last %@",
                                    model.systemProxyGuardRepairCount,
                                    AppLocalization.relativeDate(repairedAt)
                                )
                            )
                            .help(
                                repairedAt.formatted(
                                    .dateTime
                                        .year()
                                        .month(.abbreviated)
                                        .day()
                                        .hour()
                                        .minute()
                                        .second()
                                        .locale(AppLocalization.selectedLocale)
                                )
                            )
                        }
                        Button(
                            AppLocalization.string(
                                model.systemProxyPreferences.guardEnabled
                                    ? "Pause Proxy Guard"
                                    : "Resume Proxy Guard"
                            )
                        ) {
                            Task {
                                await model.setSystemProxyGuardPaused(
                                    model.systemProxyPreferences.guardEnabled
                                )
                            }
                        }
                        .disabled(!model.canPerform(.changeSystemProxySettings))
                    }

                    Button("Edit Bypass & Guard…") {
                        showingSystemProxySettings = true
                    }
                    .disabled(!model.canPerform(.changeSystemProxySettings))
                }
                appRoutingFeedback
                systemProxySettingsFeedback
            }

            if let applicationSettingsError {
                Section {
                    Label(applicationSettingsError, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.red)
                }
            }

            Section("Updates & Notifications") {
                Toggle(
                    "Automatically check for MClash updates",
                    isOn: Binding(
                        get: { applicationUpdater.automaticallyChecksForUpdates },
                        set: { applicationUpdater.setAutomaticallyChecksForUpdates($0) }
                    )
                )
                Toggle(
                    "Automatically download updates",
                    isOn: Binding(
                        get: { applicationUpdater.automaticallyDownloadsUpdates },
                        set: { applicationUpdater.setAutomaticallyDownloadsUpdates($0) }
                    )
                )
                .disabled(!applicationUpdater.allowsAutomaticUpdates)
                Toggle(
                    "Notify me about core failures",
                    isOn: Binding(
                        get: { model.notificationsEnabled },
                        set: { enabled in
                            Task { await model.setNotificationsEnabled(enabled) }
                        }
                    )
                )
                .disabled(!model.canPerform(.changeApplicationSettings))
                Button("Check for Updates…") {
                    applicationUpdater.checkForUpdates()
                }
                .disabled(!applicationUpdater.canCheckForUpdates)
                Text("Updates are signed and restore macOS proxy settings before installation.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                DisclosureGroup("Advanced", isExpanded: $advancedSettingsExpanded) {
                    if model.unifiedConfigurationEnabled {
                        Button(AppLocalization.string("Entrances")) {
                            model.selection = .entrances
                        }
                        Text(AppLocalization.string("HTTP, SOCKS5, and App Routing are managed on the Entrances page in unified Configuration."))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        Button(
                            AppLocalization.string(
                                model.isConnected ? "Edit Ports & Restart…" : "Edit Ports…"
                            )
                        ) {
                            showingListenerPortSettings = true
                        }
                        .disabled(!model.canPerform(.changeRuntimeSettings))

                        Button(
                            AppLocalization.string(
                                model.isConnected
                                    ? "Manage Dedicated Ports & Restart…"
                                    : "Manage Dedicated Ports…"
                            )
                        ) {
                            showingProfileRouteListenerSettings = true
                        }
                        .disabled(
                            model.profiles.isEmpty
                                || !model.canPerform(.changeRuntimeSettings)
                        )
                    }

                    runtimeSettingsFeedback

                    HStack {
                        Button("Export Backup…") {
                            Task { await model.exportBackup() }
                        }
                        .disabled(!model.canPerform(.exportBackup))

                        Button("Restore Backup…") {
                            Task { await model.restoreBackup() }
                        }
                        .disabled(!model.canPerform(.restoreBackup))
                    }
                    Text("Backups may contain subscription URLs and proxy credentials. Store them securely.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    LabeledContent("Command Line Tool") {
                        Button(commandLineToolButtonTitle) {
                            updateCommandLineToolInstallation()
                        }
                        .disabled(
                            commandLineToolStatus == .conflict
                                || commandLineToolStatus == .unsafeSource
                                || commandLineToolStatus == .unsafeParent
                                || commandLineToolStatus == .unavailable
                        )
                    }
                    Text("Install a link at ~/.local/bin/mclashctl so Terminal and local agents can use mclashctl. Add ~/.local/bin to your PATH if needed.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    commandLineToolFeedback

                    if model.unifiedConfigurationEnabled {
                        Text(AppLocalization.string("Runtime policy is owned by MClash Configuration; imported source settings are not edited here."))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        Button("Edit Runtime Configuration…") {
                            showingRuntimeSettings = true
                        }
                        .disabled(!model.canPerform(.changeRuntimeSettings))
                    }

                    DisclosureGroup("Core Details", isExpanded: $coreDetailsExpanded) {
                        LabeledContent("Distribution", value: "Bundled mihomo Alpha")
                        LabeledContent(
                            "Version",
                            value: model.runningSession?.version
                                ?? AppLocalization.string("Verified during build")
                        )
                        LabeledContent("Controller") {
                            if let controllerAddress {
                                CopyableValueButton(
                                    value: controllerAddress,
                                    accessibilityName: AppLocalization.string(
                                        "controller address"
                                    )
                                )
                            } else {
                                Text("Assigned when connecting")
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Text("The controller credential is generated in memory for each app launch.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .contentMargins(.horizontal, MClashLayout.pagePadding, for: .scrollContent)
        .contentMargins(.vertical, 20, for: .scrollContent)
        .navigationTitle("Settings")
        .mclashPageSurface()
        .onAppear {
            refreshCommandLineToolStatus()
        }
        .sheet(isPresented: $showingRuntimeSettings) {
            RuntimeSettingsEditor(
                model: model,
                isPresented: $showingRuntimeSettings
            )
        }
        .sheet(isPresented: $showingListenerPortSettings) {
            ListenerPortSettingsEditor(
                model: model,
                isPresented: $showingListenerPortSettings
            )
        }
        .sheet(isPresented: $showingProfileRouteListenerSettings) {
            ProfileRouteListenerSettingsEditor(
                model: model,
                isPresented: $showingProfileRouteListenerSettings
            )
        }
        .sheet(isPresented: $showingSystemProxySettings) {
            SystemProxySettingsEditor(
                model: model,
                isPresented: $showingSystemProxySettings
            )
        }
    }

    private var controllerAddress: String? {
        guard let endpoint = model.runningSession?.endpoint,
              let host = endpoint.host(),
              let port = endpoint.port else {
            return nil
        }
        return "\(host):\(port)"
    }

    private var commandLineToolButtonTitle: String {
        AppLocalization.string(
            commandLineToolStatus == .installed
                ? "Remove Command Line Tool"
                : "Install Command Line Tool"
        )
    }

    @ViewBuilder
    private var commandLineToolFeedback: some View {
        if let commandLineToolError {
            Label(commandLineToolError, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        } else if commandLineToolStatus == .conflict {
            Label(
                "~/.local/bin/mclashctl already exists. MClash will not replace it.",
                systemImage: "exclamationmark.triangle.fill"
            )
            .font(.caption)
            .foregroundStyle(.orange)
            .fixedSize(horizontal: false, vertical: true)
        } else if commandLineToolStatus == .unavailable {
            Label(
                "The bundled mclashctl helper is missing or not executable.",
                systemImage: "exclamationmark.triangle.fill"
            )
            .font(.caption)
            .foregroundStyle(.red)
            .fixedSize(horizontal: false, vertical: true)
        } else if commandLineToolStatus == .unsafeSource {
            Label(
                "Move MClash directly to /Applications before installing its command-line tool.",
                systemImage: "exclamationmark.triangle.fill"
            )
            .font(.caption)
            .foregroundStyle(.red)
            .fixedSize(horizontal: false, vertical: true)
        } else if commandLineToolStatus == .unsafeParent {
            Label(
                "~/.local and ~/.local/bin must be directories owned by you and not writable by other users.",
                systemImage: "exclamationmark.triangle.fill"
            )
            .font(.caption)
            .foregroundStyle(.red)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func updateCommandLineToolInstallation() {
        let installer = CommandLineToolInstaller()
        do {
            if commandLineToolStatus == .installed {
                try installer.remove()
            } else {
                try installer.install()
            }
            commandLineToolError = nil
        } catch {
            commandLineToolError = error.localizedDescription
        }
        commandLineToolStatus = installer.status
    }

    private func refreshCommandLineToolStatus() {
        commandLineToolStatus = CommandLineToolInstaller().status
        commandLineToolError = nil
    }

    @ViewBuilder
    private var systemProxySettingsFeedback: some View {
        if let receipt = model.systemProxySettingsReceipt {
            switch receipt.outcome {
            case .savedForNextConnection:
                Label("Proxy settings saved for the next connection.", systemImage: "checkmark.circle")
                    .foregroundStyle(.green)
            case .appliedAndVerified:
                Label("Proxy settings applied and verified by macOS.", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            case let .rejectedAndRolledBack(message):
                Label("New settings were rejected; the previous verified settings were restored.", systemImage: "arrow.uturn.backward.circle.fill")
                    .foregroundStyle(.orange)
                    .help(message)
            case let .rollbackFailed(message):
                Label("New settings failed and the previous settings could not be restored.", systemImage: "exclamationmark.octagon.fill")
                    .foregroundStyle(.red)
                    .help(message)
            }
        }
    }

    @ViewBuilder
    private var runtimeSettingsFeedback: some View {
        switch model.runtimeSettingsApplyState {
        case .idle:
            EmptyView()
        case .validating:
            settingsProgressLabel("Validating configuration…")
        case .restarting:
            settingsProgressLabel("Restarting the core…")
        case .saving:
            settingsProgressLabel("Saving settings…")
        case let .completed(outcome):
            Label(runtimeSettingsCompletionTitle(outcome), systemImage: "checkmark.circle.fill")
                .font(.callout)
                .foregroundStyle(.green)
        case let .failed(message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.callout)
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var appRoutingFeedback: some View {
        switch model.networkCaptureState {
        case .awaitingUserApproval:
            Label(
                "Approve MClash in System Settings → General → Login Items & Extensions → Network Extensions.",
                systemImage: "lock.shield.fill"
            )
            .font(.caption)
            .foregroundStyle(.orange)
            .fixedSize(horizontal: false, vertical: true)
        case let .failed(message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        case .requiresReboot:
            Label("Restart your Mac to finish enabling App Routing.", systemImage: "restart.circle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
        case .off, .waitingForConnection, .enabling, .on, .disabling:
            EmptyView()
        }
    }

    private func settingsProgressLabel(_ title: String) -> some View {
        HStack(spacing: 7) {
            ProgressView()
                .controlSize(.small)
            Text(AppLocalization.string(title))
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private func runtimeSettingsCompletionTitle(
        _ outcome: AppModel.RuntimeSettingsApplyOutcome
    ) -> String {
        switch outcome {
        case .unchanged: AppLocalization.string("Settings are already up to date.")
        case .saved: AppLocalization.string("Settings saved for the next connection.")
        case .savedAndRestarted:
            AppLocalization.string("Settings applied · Core restarted.")
        }
    }

    private var launchAtLoginBinding: Binding<Bool> {
        Binding(
            get: { model.launchAtLogin },
            set: { enabled in
                do {
                    try model.setLaunchAtLogin(enabled)
                    applicationSettingsError = nil
                } catch {
                    applicationSettingsError = error.localizedDescription
                }
            }
        )
    }
}

private struct SystemProxySettingsEditor: View {
    @Bindable var model: AppModel
    @Binding var isPresented: Bool
    @State private var bypassPrivateNetworks: Bool
    @State private var guardEnabled: Bool
    @State private var guardIntervalSeconds: Int
    @State private var customBypassText: String
    @State private var customBypassExpanded = false
    @State private var saveTask: Task<Void, Never>?
    @State private var errorMessage: String?

    init(model: AppModel, isPresented: Binding<Bool>) {
        self.model = model
        _isPresented = isPresented
        let preferences = model.systemProxyPreferences
        _bypassPrivateNetworks = State(initialValue: preferences.bypassPrivateNetworks)
        _guardEnabled = State(initialValue: preferences.guardEnabled)
        _guardIntervalSeconds = State(initialValue: preferences.guardIntervalSeconds)
        _customBypassText = State(
            initialValue: preferences.customBypassDomains.joined(separator: "\n")
        )
        _customBypassExpanded = State(
            initialValue: !preferences.customBypassDomains.isEmpty
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("System Proxy Settings")
                .font(.title2.weight(.semibold))

            Form {
                Section("Bypass") {
                    Toggle("Bypass private and link-local networks", isOn: $bypassPrivateNetworks)
                    Text("localhost, loopback, and .local names are always bypassed.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    DisclosureGroup(
                        "Custom domains or patterns",
                        isExpanded: $customBypassExpanded
                    ) {
                        TextEditor(text: $customBypassText)
                            .font(.body.monospaced())
                            .frame(minHeight: 110)
                            .accessibilityLabel(AppLocalization.string("Custom domains or patterns"))
                            .accessibilityHint(AppLocalization.string("One value per line"))
                        Text("Enter one value per line, for example *.example.com.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Guard") {
                    Toggle("Restore the system proxy if another app changes it", isOn: $guardEnabled)
                    if guardEnabled {
                        Stepper(
                            AppLocalization.format(
                                "Check every %d seconds",
                                guardIntervalSeconds
                            ),
                            value: $guardIntervalSeconds,
                            in: 2...300
                        )
                        Label(
                            "While active, MClash rewrites changed macOS proxy settings back to its local listeners. This can override Proxifier or another proxy app. Pause the guard before another app takes ownership.",
                            systemImage: "exclamationmark.triangle.fill"
                        )
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                    } else {
                        Text("Paused: MClash leaves later macOS proxy changes untouched. The current proxy remains enabled until you turn it off.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped)

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.red)
            }

            HStack(spacing: 10) {
                if isSaving {
                    ProgressView()
                        .controlSize(.small)
                    Text("Saving and applying…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel", role: .cancel) { isPresented = false }
                    .keyboardShortcut(.cancelAction)
                    .disabled(isSaving)
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(isSaving || !model.canPerform(.changeSystemProxySettings))
            }
        }
        .padding(24)
        .frame(minWidth: 500, idealWidth: 560, minHeight: 500, idealHeight: 560)
        .interactiveDismissDisabled(isSaving)
    }

    private var isSaving: Bool { saveTask != nil }

    private var customBypassDomains: [String] {
        customBypassText
            .components(separatedBy: .newlines)
            .flatMap { $0.split(separator: ",").map(String.init) }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private func save() {
        guard saveTask == nil else { return }
        errorMessage = nil
        let preferences = SystemProxyPreferences(
            customBypassDomains: customBypassDomains,
            bypassPrivateNetworks: bypassPrivateNetworks,
            guardEnabled: guardEnabled,
            guardIntervalSeconds: guardIntervalSeconds
        )
        saveTask = Task {
            do {
                try await model.applySystemProxyPreferences(preferences)
                if !Task.isCancelled {
                    await MainActor.run { isPresented = false }
                }
            } catch is CancellationError {
                // Closing the sheet cancels its work.
            } catch {
                if !Task.isCancelled {
                    await MainActor.run { errorMessage = error.localizedDescription }
                }
            }
            await MainActor.run { saveTask = nil }
        }
    }

}

private struct RuntimeSettingsEditor: View {
    @Bindable var model: AppModel
    @Binding var isPresented: Bool
    @State private var overrides: RuntimeOverrides
    @State private var saveTask: Task<Void, Never>?
    @State private var errorMessage: String?
    @State private var portsExpanded = false
    @State private var networkExpanded = false
    @State private var coreExpanded = false
    @State private var dnsExpanded = false
    @State private var rulesExpanded = false

    init(model: AppModel, isPresented: Binding<Bool>) {
        self.model = model
        _isPresented = isPresented
        let overrides = model.runtimeOverrides
        _overrides = State(initialValue: overrides)
        _portsExpanded = State(
            initialValue: overrides.ports.redirPort != nil
                || overrides.ports.tproxyPort != nil
        )
        _networkExpanded = State(
            initialValue: overrides.allowLAN != nil
                || overrides.bindAddress != nil
                || overrides.ipv6 != nil
                || overrides.sniffing != nil
                || overrides.tcpConcurrent != nil
                || overrides.interfaceName != nil
        )
        _coreExpanded = State(
            initialValue: overrides.findProcessMode != nil || overrides.logLevel != nil
        )
        _dnsExpanded = State(initialValue: overrides.dns != nil)
        _rulesExpanded = State(
            initialValue: overrides.prependRules != nil || overrides.appendRules != nil
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Runtime Configuration")
                    .font(.title2.weight(.semibold))
                Text("Use Profile keeps the value supplied by the active profile. Saving validates the final YAML before it is activated.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Form {
                Section {
                    DisclosureGroup("Transparent Proxy Ports", isExpanded: $portsExpanded) {
                        OptionalPortField("Redirect", value: $overrides.ports.redirPort, suggestedValue: 0)
                        OptionalPortField("TProxy", value: $overrides.ports.tproxyPort, suggestedValue: 0)
                        Text(AppLocalization.string(
                            model.unifiedConfigurationEnabled
                                ? "Unified Configuration owns named HTTP and SOCKS5 entrances on the Entrances page."
                                : "The Mixed port is configured from Local Proxy settings. Separate HTTP and SOCKS5 listeners are disabled by MClash."
                        ))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section {
                    DisclosureGroup("Network", isExpanded: $networkExpanded) {
                        OptionalBooleanPicker("Allow LAN", value: $overrides.allowLAN)
                        OptionalStringField(
                            "Bind address",
                            value: $overrides.bindAddress,
                            suggestedValue: "*"
                        )
                        OptionalBooleanPicker("IPv6", value: $overrides.ipv6)
                        OptionalBooleanPicker("Sniffing", value: $overrides.sniffing)
                        OptionalBooleanPicker("TCP concurrent dialing", value: $overrides.tcpConcurrent)
                        OptionalStringField(
                            "Outbound interface",
                            value: $overrides.interfaceName,
                            suggestedValue: "en0"
                        )
                    }
                }

                Section {
                    DisclosureGroup("Core", isExpanded: $coreExpanded) {
                        Picker("Process lookup", selection: $overrides.findProcessMode) {
                            Text("Use Profile").tag(nil as String?)
                            Text("Strict").tag("strict" as String?)
                            Text("Always").tag("always" as String?)
                            Text("Off").tag("off" as String?)
                        }
                        Picker("Log level", selection: $overrides.logLevel) {
                            Text("Use Profile").tag(nil as String?)
                            ForEach(MihomoLogLevel.allCases, id: \.rawValue) { level in
                                Text(
                                    AppLocalization.string(
                                        level == .info
                                            ? "Information"
                                            : level.rawValue.capitalized
                                    )
                                )
                                    .tag(level.rawValue as String?)
                            }
                        }
                    }
                }

                Section {
                    DisclosureGroup("DNS", isExpanded: $dnsExpanded) {
                        Toggle("Override the profile DNS section", isOn: dnsOverrideEnabled)
                        if overrides.dns != nil {
                            Text("This replaces the complete DNS section; fields left on Use Default use mihomo defaults, not values from the profile.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            OptionalBooleanPicker("DNS service", value: dnsBinding(\.enable))
                            OptionalStringField(
                                "Listen address",
                                value: dnsBinding(\.listen),
                                suggestedValue: "0.0.0.0:1053"
                            )
                            OptionalBooleanPicker("DNS IPv6", value: dnsBinding(\.ipv6))
                            Picker("Enhanced mode", selection: dnsBinding(\.enhancedMode)) {
                                Text("Use Default").tag(nil as RuntimeDNSEnhancedMode?)
                                Text("Fake IP").tag(RuntimeDNSEnhancedMode.fakeIP as RuntimeDNSEnhancedMode?)
                                Text("Redir Host").tag(RuntimeDNSEnhancedMode.redirHost as RuntimeDNSEnhancedMode?)
                            }
                            OptionalStringField(
                                "Fake IP range",
                                value: dnsBinding(\.fakeIPRange),
                                suggestedValue: "198.18.0.1/16"
                            )
                            OptionalBooleanPicker("Respect routing rules", value: dnsBinding(\.respectRules))
                            OptionalBooleanPicker("Use configured hosts", value: dnsBinding(\.useHosts))
                            OptionalBooleanPicker("Use system hosts", value: dnsBinding(\.useSystemHosts))
                            OptionalBooleanPicker("Prefer HTTP/3", value: dnsBinding(\.preferH3))
                            OptionalStringListField(
                                "Default nameservers",
                                value: dnsBinding(\.defaultNameserver),
                                suggestedValues: ["223.5.5.5", "1.1.1.1"]
                            )
                            OptionalStringListField(
                                "Nameservers",
                                value: dnsBinding(\.nameserver),
                                suggestedValues: ["https://1.1.1.1/dns-query"]
                            )
                            OptionalStringListField(
                                "Fallback nameservers",
                                value: dnsBinding(\.fallback),
                                suggestedValues: []
                            )
                            OptionalStringListField(
                                "Proxy nameservers",
                                value: dnsBinding(\.proxyServerNameserver),
                                suggestedValues: ["https://1.1.1.1/dns-query"]
                            )
                            OptionalStringListField(
                                "Direct nameservers",
                                value: dnsBinding(\.directNameserver),
                                suggestedValues: ["system"]
                            )
                            OptionalStringListField(
                                "Fake IP filter",
                                value: dnsBinding(\.fakeIPFilter),
                                suggestedValues: ["*.lan", "+.local"]
                            )
                        }
                    }
                }

                Section {
                    DisclosureGroup("Rule Overrides", isExpanded: $rulesExpanded) {
                        Text("Prepend rules take priority over profile rules; append rules run after them. Each rule must occupy one line.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        OptionalStringListField(
                            "Prepend rules",
                            value: $overrides.prependRules,
                            suggestedValues: []
                        )
                        OptionalStringListField(
                            "Append rules",
                            value: $overrides.appendRules,
                            suggestedValues: []
                        )
                    }
                }
            }
            .formStyle(.grouped)

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 10) {
                Button("Reset Advanced Settings") {
                    let commonPorts = RuntimePortOverrides(
                        port: overrides.ports.port,
                        socksPort: overrides.ports.socksPort,
                        mixedPort: overrides.ports.mixedPort
                    )
                    overrides = .empty
                    overrides.ports = commonPorts
                    errorMessage = nil
                }
                .help("Keep local proxy ports and reset the advanced overrides in this editor")
                .disabled(isSaving)

                if isSaving {
                    ProgressView()
                        .controlSize(.small)
                    Text(
                        AppLocalization.string(
                            model.isConnected
                                ? "Validating and restarting…"
                                : "Validating and applying…"
                        )
                    )
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                Spacer()
                Button("Cancel", role: .cancel) { isPresented = false }
                    .keyboardShortcut(.cancelAction)
                    .disabled(isSaving)
                Button(
                    AppLocalization.string(
                        model.isConnected ? "Apply & Restart Core" : "Save"
                    )
                ) { save() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(isSaving || !model.canPerform(.changeRuntimeSettings))
            }
        }
        .padding(24)
        .frame(minWidth: 560, idealWidth: 620, minHeight: 520, idealHeight: 680, maxHeight: 760)
        .interactiveDismissDisabled(isSaving)
    }

    private var isSaving: Bool {
        saveTask != nil
    }

    private var dnsOverrideEnabled: Binding<Bool> {
        Binding(
            get: { overrides.dns != nil },
            set: { enabled in
                if enabled {
                    overrides.dns = overrides.dns ?? RuntimeDNSOverrides(
                        enable: true,
                        ipv6: false,
                        enhancedMode: .fakeIP,
                        fakeIPRange: "198.18.0.1/16",
                        defaultNameserver: ["223.5.5.5", "1.1.1.1"],
                        nameserver: ["https://1.1.1.1/dns-query"],
                        respectRules: true,
                        useHosts: true,
                        useSystemHosts: true,
                        preferH3: false
                    )
                } else {
                    overrides.dns = nil
                }
            }
        )
    }

    private func dnsBinding<Value>(
        _ keyPath: WritableKeyPath<RuntimeDNSOverrides, Value>
    ) -> Binding<Value> {
        Binding(
            get: { (overrides.dns ?? RuntimeDNSOverrides())[keyPath: keyPath] },
            set: { value in
                var dns = overrides.dns ?? RuntimeDNSOverrides()
                dns[keyPath: keyPath] = value
                overrides.dns = dns
            }
        )
    }

    private func save() {
        guard saveTask == nil else { return }
        errorMessage = nil
        saveTask = Task {
            do {
                try await model.applyRuntimeOverrides(overrides)
                if !Task.isCancelled {
                    await MainActor.run { isPresented = false }
                }
            } catch is CancellationError {
                // Dismissing the sheet cancels its operation.
            } catch {
                if !Task.isCancelled {
                    await MainActor.run { errorMessage = error.localizedDescription }
                }
            }
            await MainActor.run { saveTask = nil }
        }
    }

}

private struct OptionalBooleanPicker: View {
    let title: String
    @Binding var value: Bool?

    init(_ title: String, value: Binding<Bool?>) {
        self.title = title
        _value = value
    }

    var body: some View {
        Picker(AppLocalization.string(title), selection: $value) {
            Text("Use Profile").tag(nil as Bool?)
            Text("Enabled").tag(true as Bool?)
            Text("Disabled").tag(false as Bool?)
        }
    }
}

private struct OptionalPortField: View {
    let title: String
    @Binding var value: Int?
    let suggestedValue: Int

    init(_ title: String, value: Binding<Int?>, suggestedValue: Int) {
        self.title = title
        _value = value
        self.suggestedValue = suggestedValue
    }

    var body: some View {
        HStack {
            Toggle(AppLocalization.string(title), isOn: overrideEnabled)
            Spacer()
            TextField("Port", value: concreteValue, format: .number)
                .multilineTextAlignment(.trailing)
                .frame(width: 90)
                .disabled(value == nil)
                .accessibilityLabel(
                    AppLocalization.format("%@ port", AppLocalization.string(title))
                )
        }
    }

    private var overrideEnabled: Binding<Bool> {
        Binding(
            get: { value != nil },
            set: { enabled in value = enabled ? (value ?? suggestedValue) : nil }
        )
    }

    private var concreteValue: Binding<Int> {
        Binding(
            get: { value ?? suggestedValue },
            set: { value = $0 }
        )
    }
}

private struct OptionalStringField: View {
    let title: String
    @Binding var value: String?
    let suggestedValue: String

    init(_ title: String, value: Binding<String?>, suggestedValue: String) {
        self.title = title
        _value = value
        self.suggestedValue = suggestedValue
    }

    var body: some View {
        HStack {
            Toggle(AppLocalization.string(title), isOn: overrideEnabled)
            Spacer()
            TextField("Value", text: concreteValue)
                .multilineTextAlignment(.trailing)
                .frame(width: 180)
                .disabled(value == nil)
                .accessibilityLabel(AppLocalization.string(title))
        }
    }

    private var overrideEnabled: Binding<Bool> {
        Binding(
            get: { value != nil },
            set: { enabled in value = enabled ? (value ?? suggestedValue) : nil }
        )
    }

    private var concreteValue: Binding<String> {
        Binding(
            get: { value ?? suggestedValue },
            set: { value = $0 }
        )
    }
}

private struct OptionalStringListField: View {
    let title: String
    @Binding var value: [String]?
    let suggestedValues: [String]

    init(_ title: String, value: Binding<[String]?>, suggestedValues: [String]) {
        self.title = title
        _value = value
        self.suggestedValues = suggestedValues
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(localizedTitle, isOn: overrideEnabled)
            if value != nil {
                TextEditor(text: textValue)
                    .font(.body.monospaced())
                    .frame(minHeight: 70)
                    .accessibilityLabel(localizedTitle)
                    .accessibilityHint(AppLocalization.string("One value per line"))
                Text("One value per line. An enabled empty list clears this field.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var localizedTitle: String {
        AppLocalization.string(title)
    }

    private var overrideEnabled: Binding<Bool> {
        Binding(
            get: { value != nil },
            set: { enabled in value = enabled ? (value ?? suggestedValues) : nil }
        )
    }

    private var textValue: Binding<String> {
        Binding(
            get: { (value ?? []).joined(separator: "\n") },
            set: { text in
                value = text.components(separatedBy: .newlines)
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
            }
        )
    }
}
