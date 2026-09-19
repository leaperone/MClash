import SwiftUI

struct SourceEditorSheet: View {
    @Bindable var model: AppModel
    let profile: ProfileMetadata
    @Binding var isPresented: Bool
    @State private var name: String
    @State private var address: String
    @State private var automaticUpdates = true
    @State private var customInterval = false
    @State private var advancedExpanded = false
    @State private var intervalHours = 24
    @State private var isSaving = false
    @State private var error: String?

    private var isRemote: Bool {
        if case .remote = profile.origin { return true }
        return false
    }

    init(model: AppModel, profile: ProfileMetadata, isPresented: Binding<Bool>) {
        self.model = model
        self.profile = profile
        _isPresented = isPresented
        _name = State(initialValue: profile.name)
        if case let .remote(remote) = profile.origin {
            _address = State(initialValue: remote.url.absoluteString)
            _automaticUpdates = State(initialValue: remote.automaticUpdatesEnabled)
            _customInterval = State(initialValue: remote.updateIntervalHours != nil)
            _advancedExpanded = State(initialValue: remote.updateIntervalHours != nil)
            _intervalHours = State(initialValue: remote.updateIntervalHours ?? 24)
        } else {
            _address = State(initialValue: "")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(AppLocalization.string("Edit source"))
                .font(.title2.weight(.semibold))
            Form {
                TextField(AppLocalization.string("Source name"), text: $name)
                    .disabled(isSaving)
                    .accessibilityIdentifier("source-editor.name")
                if isRemote {
                    Section(AppLocalization.string("Subscription")) {
                        TextField(AppLocalization.string("Subscription URL"), text: $address)
                            .textContentType(.URL)
                            .privacySensitive()
                            .disabled(isSaving)
                        Toggle(AppLocalization.string("Update automatically"), isOn: $automaticUpdates)
                            .disabled(isSaving)
                        DisclosureGroup(AppLocalization.string("Advanced update settings"), isExpanded: $advancedExpanded) {
                            Toggle(AppLocalization.string("Use a custom update interval"), isOn: $customInterval)
                                .disabled(isSaving || !automaticUpdates)
                            Stepper(
                                AppLocalization.format("Update every %d hours", intervalHours),
                                value: $intervalHours,
                                in: 1...8_760
                            )
                            .disabled(isSaving || !automaticUpdates || !customInterval)
                        }
                    }
                }
            }
            if let error {
                Text(error).font(.callout).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button(AppLocalization.string("Cancel")) { isPresented = false }
                    .keyboardShortcut(.cancelAction)
                    .disabled(isSaving)
                Button(AppLocalization.string("Save")) { save() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(isSaving || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("source-editor.save")
            }
        }
        .padding(24)
        .frame(minWidth: 420, minHeight: 300)
    }

    private func save() {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let url: URL?
        if isRemote {
            guard let parsed = URL(string: address.trimmingCharacters(in: .whitespacesAndNewlines)),
                  ["http", "https"].contains(parsed.scheme?.lowercased() ?? ""),
                  parsed.host?.isEmpty == false else {
                error = AppLocalization.string("Enter a valid subscription URL.")
                return
            }
            url = parsed
        } else {
            url = nil
        }
        isSaving = true
        error = nil
        Task {
            do {
                try await model.updateProfile(
                    profile.id,
                    name: trimmedName,
                    subscriptionURL: url,
                    automaticUpdatesEnabled: automaticUpdates,
                    updateIntervalHours: customInterval ? intervalHours : nil
                )
                isPresented = false
            } catch {
                self.error = error.localizedDescription
                isSaving = false
            }
        }
    }
}
