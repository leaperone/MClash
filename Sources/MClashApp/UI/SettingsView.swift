import AppKit
import SwiftUI

struct SettingsView: View {
    @Bindable var model: AppModel
    @Bindable var applicationUpdater: ApplicationUpdater
    @State private var coreDetailsExpanded = false
    @State private var showingListenerPortSettings = false
    @State private var showingRuntimeSettings = false
    @State private var showingSystemProxySettings = false
    @State private var applicationSettingsError: String?

    var body: some View {
        Form {
            Section("Startup") {
                Toggle("Open MClash at login", isOn: launchAtLoginBinding)
                Toggle("Connect the active profile when MClash opens", isOn: $model.autoConnectOnLaunch)
            }

            Section("Routing & macOS Proxy") {
                Toggle("Enable macOS system proxy when connecting", isOn: $model.autoEnableSystemProxy)
                Toggle(
                    "Close existing connections after changing mode or node",
                    isOn: $model.closeConnectionsOnRoutingChange
                )

                LabeledContent("Current status", value: systemProxyStatus)

                Button("Bypass & Guard Settings…") {
                    showingSystemProxySettings = true
                }
                .disabled(!model.canPerform(.changeSystemProxySettings))
            }

            Section("App Routing") {
                LabeledContent("Current status", value: appRoutingStatus)
                LabeledContent(
                    "Rules",
                    value: "\(model.networkCapturePreferences.snapshot.rules.count)"
                )
                Button("Manage App Routing…") {
                    model.selection = .appRouting
                }
                Text("Choose which applications, processes, destinations, and ports are handled by Mihomo.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Local Proxy") {
                if model.localListenerEndpoints.isEmpty {
                    Text(
                        model.isConnected
                            ? "No local listener is currently available."
                            : "Connect the active profile to see its live listener addresses."
                    )
                    .foregroundStyle(.secondary)
                } else {
                    ForEach(model.localListenerEndpoints) { endpoint in
                        listenerAddressRow(endpoint)
                    }
                }

                Button(model.isConnected ? "Edit Ports & Restart…" : "Edit Ports…") {
                    showingListenerPortSettings = true
                }
                .disabled(!model.canPerform(.changeRuntimeSettings))

                runtimeSettingsFeedback

                Text("HTTP also handles HTTPS proxy connections. Mixed accepts both HTTP and SOCKS5 on one port. Port changes are validated and automatically restart a running core.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let applicationSettingsError {
                Section {
                    Label(applicationSettingsError, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.red)
                }
            }

            Section("Profiles & Backup") {
                LabeledContent("Active profile", value: activeProfileName)
                Button("Manage Profiles…") {
                    model.selection = .profiles
                }
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
                Text("Backups are unencrypted and may contain subscription URLs and proxy credentials. Store them securely. Runtime caches and macOS proxy recovery snapshots are excluded.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
                HStack {
                    Button("Check for Updates…") {
                        applicationUpdater.checkForUpdates()
                    }
                    .disabled(!applicationUpdater.canCheckForUpdates)
                }
                Text("Updates are verified by Sparkle and Apple code signing. Before replacing the app, MClash safely restores the macOS system proxy and stops its core.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Advanced") {
                Button("Runtime Configuration…") {
                    showingRuntimeSettings = true
                }
                .disabled(!model.canPerform(.changeRuntimeSettings))

                Text("Override network, DNS, routing rules, process lookup, interface, concurrency, and core logging without modifying the subscription file.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                DisclosureGroup("Core Details", isExpanded: $coreDetailsExpanded) {
                    LabeledContent("Distribution", value: "Bundled mihomo Alpha")
                    LabeledContent(
                        "Version",
                        value: model.runningSession?.version ?? "Verified during build"
                    )
                    LabeledContent("Controller") {
                        if let controllerAddress {
                            CopyableValueButton(
                                value: controllerAddress,
                                accessibilityName: "controller address"
                            )
                        } else {
                            Text("Assigned when connecting")
                                .foregroundStyle(.secondary)
                        }
                    }
                    Text("The controller credential is generated in memory for each app launch. MClash does not request Keychain access when connecting.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .contentMargins(.horizontal, MClashLayout.pagePadding, for: .scrollContent)
        .contentMargins(.vertical, 20, for: .scrollContent)
        .navigationTitle("Settings")
        .mclashPageSurface()
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
        .sheet(isPresented: $showingSystemProxySettings) {
            SystemProxySettingsEditor(
                model: model,
                isPresented: $showingSystemProxySettings
            )
        }
    }

    private var activeProfileName: String {
        guard let activeProfileID = model.activeProfileID else { return "None" }
        return model.profiles.first(where: { $0.id == activeProfileID })?.name ?? "Active profile"
    }

    private var controllerAddress: String? {
        guard let endpoint = model.runningSession?.endpoint,
              let host = endpoint.host(),
              let port = endpoint.port else {
            return nil
        }
        return "\(host):\(port)"
    }

    private var systemProxyStatus: String {
        if model.pendingSystemProxyEnabled == true { return "Turning On" }
        if model.pendingSystemProxyEnabled == false { return "Turning Off" }
        if model.systemProxyRecoveryRequired { return "Needs Restoration" }
        return model.systemProxyEnabled ? "On" : "Off"
    }

    private func listenerAddressRow(_ endpoint: AppModel.LocalListenerEndpoint) -> some View {
        LabeledContent(endpoint.kind.presentationTitle) {
            HStack(spacing: 8) {
                Text(endpoint.source.presentationTitle)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.quaternary, in: Capsule())
                CopyableValueButton(
                    value: endpoint.address,
                    accessibilityName: "\(endpoint.kind.presentationTitle) proxy address"
                )
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

    private var appRoutingStatus: String {
        if let pending = model.pendingNetworkCaptureEnabled {
            return pending ? "Turning On" : "Turning Off"
        }
        return switch model.networkCaptureState {
        case .off: "Off"
        case .enabling: "Starting"
        case let .on(revision): "On · revision \(revision)"
        case .disabling: "Stopping"
        case .requiresReboot: "Restart Required"
        case .failed: "Needs Attention"
        }
    }

    private func settingsProgressLabel(_ title: String) -> some View {
        HStack(spacing: 7) {
            ProgressView()
                .controlSize(.small)
            Text(title)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private func runtimeSettingsCompletionTitle(
        _ outcome: AppModel.RuntimeSettingsApplyOutcome
    ) -> String {
        switch outcome {
        case .unchanged: "Settings are already up to date."
        case .saved: "Settings saved for the next connection."
        case .savedAndRestarted: "Settings applied · Core restarted."
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

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Custom domains or patterns")
                        TextEditor(text: $customBypassText)
                            .font(.body.monospaced())
                            .frame(minHeight: 110)
                        Text("Enter one value per line, for example *.example.com.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Guard") {
                    Toggle("Restore the system proxy if another app changes it", isOn: $guardEnabled)
                    if guardEnabled {
                        Stepper(
                            "Check every \(guardIntervalSeconds) seconds",
                            value: $guardIntervalSeconds,
                            in: 2...300
                        )
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

    init(model: AppModel, isPresented: Binding<Bool>) {
        self.model = model
        _isPresented = isPresented
        _overrides = State(initialValue: model.runtimeOverrides)
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
                Section("Transparent Proxy Ports") {
                    OptionalPortField("Redirect", value: $overrides.ports.redirPort, suggestedValue: 0)
                    OptionalPortField("TProxy", value: $overrides.ports.tproxyPort, suggestedValue: 0)
                    Text("HTTP, SOCKS5, and Mixed ports are configured from Local Proxy settings. A value of 0 disables these advanced listeners.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Network") {
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

                Section("Core") {
                    Picker("Process lookup", selection: $overrides.findProcessMode) {
                        Text("Use Profile").tag(nil as String?)
                        Text("Strict").tag("strict" as String?)
                        Text("Always").tag("always" as String?)
                        Text("Off").tag("off" as String?)
                    }
                    Picker("Log level", selection: $overrides.logLevel) {
                        Text("Use Profile").tag(nil as String?)
                        ForEach(MihomoLogLevel.allCases, id: \.rawValue) { level in
                            Text(level.rawValue.capitalized).tag(level.rawValue as String?)
                        }
                    }
                }

                Section("DNS") {
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

                Section("Rule Overrides") {
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
                    Text(model.isConnected ? "Validating and restarting…" : "Validating and applying…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                Spacer()
                Button("Cancel", role: .cancel) { isPresented = false }
                    .keyboardShortcut(.cancelAction)
                    .disabled(isSaving)
                Button(model.isConnected ? "Apply & Restart Core" : "Save") { save() }
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
        Picker(title, selection: $value) {
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
            Toggle(title, isOn: overrideEnabled)
            Spacer()
            TextField("Port", value: concreteValue, format: .number)
                .multilineTextAlignment(.trailing)
                .frame(width: 90)
                .disabled(value == nil)
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
            Toggle(title, isOn: overrideEnabled)
            Spacer()
            TextField("Value", text: concreteValue)
                .multilineTextAlignment(.trailing)
                .frame(width: 180)
                .disabled(value == nil)
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
            Toggle(title, isOn: overrideEnabled)
            if value != nil {
                TextEditor(text: textValue)
                    .font(.body.monospaced())
                    .frame(minHeight: 70)
                Text("One value per line. An enabled empty list clears this field.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
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
