import SwiftUI

enum ListenerPortMode: String, CaseIterable, Identifiable {
    case profile
    case custom

    var id: Self { self }

    var title: String {
        switch self {
        case .profile: "Use Profile"
        case .custom: "Custom"
        }
    }
}

struct ListenerPortDraft: Equatable {
    var mode: ListenerPortMode
    var customValue: String
    let profileValue: Int?
    let suggestedValue: Int

    init(override: Int?, effectiveValue: Int?, suggestedValue: Int) {
        profileValue = effectiveValue
        self.suggestedValue = suggestedValue
        if let override {
            mode = .custom
            customValue = String(override)
        } else {
            mode = .profile
            customValue = String(effectiveValue.flatMap { $0 > 0 ? $0 : nil } ?? suggestedValue)
        }
    }

    var overrideValue: Int? {
        switch mode {
        case .profile: nil
        case .custom: Int(customValue)
        }
    }

    var effectiveValue: Int? {
        switch mode {
        case .profile:
            return profileValue.flatMap { $0 > 0 ? $0 : nil }
        case .custom:
            guard let value = Int(customValue), value > 0 else { return nil }
            return value
        }
    }

    var validationMessage: String? {
        guard mode == .custom else { return nil }
        guard let value = Int(customValue), (1...65_535).contains(value) else {
            return "Enter a port from 1 to 65535."
        }
        return nil
    }

    mutating func useProfile() {
        mode = .profile
        customValue = String(profileValue.flatMap { $0 > 0 ? $0 : nil } ?? suggestedValue)
    }
}

struct ListenerPortSettingsDraft: Equatable {
    var mixed: ListenerPortDraft

    init(
        overrides: RuntimePortOverrides,
        profileMixedPort: Int?
    ) {
        mixed = ListenerPortDraft(
            override: overrides.mixedPort,
            effectiveValue: profileMixedPort,
            suggestedValue: 7_890
        )
    }

    var validationMessage: String? {
        if let message = mixed.validationMessage { return "Mixed: \(message)" }
        return nil
    }

    func applying(to overrides: RuntimeOverrides) -> RuntimeOverrides {
        var updated = overrides
        updated.ports.port = 0
        updated.ports.socksPort = 0
        updated.ports.mixedPort = mixed.overrideValue
        return updated
    }

    mutating func useProfileForAll() {
        mixed.useProfile()
    }
}

struct ListenerPortSettingsEditor: View {
    @Bindable var model: AppModel
    @Binding var isPresented: Bool

    @State private var draft: ListenerPortSettingsDraft
    @State private var saveTask: Task<Void, Never>?
    @State private var errorMessage: String?
    @FocusState private var focusedListener: ListenerKind?

    private enum ListenerKind: Hashable { case mixed }

    init(model: AppModel, isPresented: Binding<Bool>) {
        self.model = model
        _isPresented = isPresented
        let profilePorts = model.activeProfileListenerPorts
        _draft = State(
            initialValue: ListenerPortSettingsDraft(
                overrides: model.runtimeOverrides.ports,
                profileMixedPort: profilePorts.mixedPort
            )
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Local Proxy Port")
                    .font(.title2.weight(.semibold))
                Text("Choose one Mixed port for HTTP, HTTPS proxy, and SOCKS5 clients.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 24)
            .padding(.top, 22)
            .padding(.bottom, 14)

            Divider()

            Form {
                Section("Listeners") {
                    portRow(
                        title: "Mixed",
                        subtitle: AppLocalization.string(
                            "One port that accepts both HTTP and SOCKS5"
                        ),
                        systemImage: "arrow.triangle.branch",
                        draft: $draft.mixed,
                        kind: .mixed
                    )
                }

                Section {
                    Label(
                        model.isConnected
                            ? "Applying changes safely restarts the core. If the macOS system proxy is on, MClash restores it with the new ports."
                            : "Changes are validated now and used the next time the core connects.",
                        systemImage: model.isConnected ? "arrow.clockwise" : "checkmark.shield"
                    )
                    .font(.callout)
                    .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)

            Divider()

            VStack(alignment: .leading, spacing: 10) {
                if let visibleErrorMessage {
                    Label(visibleErrorMessage, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: 10) {
                    Button("Use Profile") {
                        draft.useProfileForAll()
                        errorMessage = nil
                    }
                    .disabled(isSaving)

                    if isSaving {
                        ProgressView()
                            .controlSize(.small)
                        Text(applyProgressTitle)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Button("Cancel", role: .cancel) { isPresented = false }
                        .keyboardShortcut(.cancelAction)
                        .disabled(isSaving)

                    Button(model.isConnected ? "Apply & Restart Core" : "Save") {
                        save()
                    }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(!canSave)
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
            .background(.bar)
        }
        .frame(minWidth: 520, idealWidth: 560, minHeight: 390, idealHeight: 430)
        .interactiveDismissDisabled(isSaving)
    }

    private var isSaving: Bool { saveTask != nil }

    private var visibleErrorMessage: String? {
        draft.validationMessage ?? errorMessage
    }

    private var applyProgressTitle: String {
        switch model.runtimeSettingsApplyState {
        case .validating:
            "Validating configuration…"
        case .restarting:
            "Restarting core…"
        case .saving:
            "Saving settings…"
        case .idle, .completed, .failed:
            model.isConnected ? "Applying and restarting…" : "Applying settings…"
        }
    }

    private var canSave: Bool {
        !isSaving
            && draft.validationMessage == nil
            && draft.applying(to: model.runtimeOverrides) != model.runtimeOverrides
            && model.canPerform(.changeRuntimeSettings)
    }

    private func portRow(
        title: String,
        subtitle: String,
        systemImage: String,
        draft: Binding<ListenerPortDraft>,
        kind: ListenerKind
    ) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: systemImage)
                .foregroundStyle(.secondary)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 12)

            Picker("\(title) source", selection: draft.mode) {
                ForEach(ListenerPortMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .labelsHidden()
            .frame(width: 118)
            .onChange(of: draft.wrappedValue.mode) { _, mode in
                errorMessage = nil
                if mode == .custom {
                    focusedListener = kind
                }
            }

            if draft.wrappedValue.mode == .custom {
                TextField("Port", text: draft.customValue)
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .monospacedDigit()
                    .frame(width: 82)
                    .focused($focusedListener, equals: kind)
                    .accessibilityLabel("\(title) custom port")
                    .onChange(of: draft.wrappedValue.customValue) { _, _ in
                        errorMessage = nil
                    }
            } else {
                Text(portSummary(draft.wrappedValue))
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 82, alignment: .trailing)
            }
        }
        .padding(.vertical, 3)
    }

    private func portSummary(_ draft: ListenerPortDraft) -> String {
        switch draft.mode {
        case .profile:
            if let profileValue = draft.profileValue {
                profileValue > 0 ? String(profileValue) : "Disabled"
            } else {
                "Not set"
            }
        case .custom:
            draft.customValue
        }
    }

    private func save() {
        guard canSave else { return }
        errorMessage = nil
        let overrides = draft.applying(to: model.runtimeOverrides)
        saveTask = Task {
            do {
                try await model.applyRuntimeOverrides(overrides)
                await MainActor.run {
                    saveTask = nil
                    isPresented = false
                }
            } catch is CancellationError {
                await MainActor.run { saveTask = nil }
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    saveTask = nil
                }
            }
        }
    }
}
