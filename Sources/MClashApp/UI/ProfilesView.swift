import SwiftUI

struct ProfilesView: View {
    @Bindable var model: AppModel
    @State private var showingSubscriptionSheet = false

    var body: some View {
        Group {
            if model.profiles.isEmpty {
                ContentUnavailableView {
                    Label("No profiles", systemImage: "doc.badge.plus")
                } description: {
                    Text("Import a YAML configuration or add a subscription to get started.")
                } actions: {
                    HStack {
                        Button("Import YAML…") { Task { await model.importProfile() } }
                            .disabled(model.networkStateTransitionInProgress)
                        Button("Add Subscription…") { showingSubscriptionSheet = true }
                            .disabled(model.networkStateTransitionInProgress)
                    }
                }
            } else {
                List(model.profiles) { profile in
                    ProfileRow(model: model, profile: profile)
                }
            }
        }
        .navigationTitle("Profiles")
        .toolbar {
            Menu {
                Button("Import YAML…") { Task { await model.importProfile() } }
                Button("Add Subscription…") { showingSubscriptionSheet = true }
            } label: {
                Label("Add Profile", systemImage: "plus")
            }
            .disabled(model.networkStateTransitionInProgress)
        }
        .sheet(isPresented: $showingSubscriptionSheet) {
            AddSubscriptionView(model: model, isPresented: $showingSubscriptionSheet)
        }
    }
}

private struct ProfileRow: View {
    @Bindable var model: AppModel
    let profile: ProfileMetadata
    @State private var confirmingDelete = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: model.activeProfileID == profile.id ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(model.activeProfileID == profile.id ? Color.accentColor : .secondary)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(profile.name)
                Text(originLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if case .remote = profile.origin {
                Button {
                    Task { await model.refreshProfile(profile.id) }
                } label: {
                    if model.isPerforming(.refreshProfile(profile.id)) {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .buttonStyle(.borderless)
                .disabled(profileOperationInProgress)
                .help("Refresh subscription")
                .accessibilityLabel("Refresh \(profile.name) subscription")
            }

            Button(model.activeProfileID == profile.id ? "Active" : "Activate") {
                Task {
                    do {
                        try await model.activateProfile(profile.id)
                    } catch {
                        model.errorMessage = error.localizedDescription
                    }
                }
            }
            .disabled(model.activeProfileID == profile.id || profileOperationInProgress)

            Menu {
                Button("Delete Profile", role: .destructive) {
                    confirmingDelete = true
                }
                .disabled(model.activeProfileID == profile.id || profileOperationInProgress)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .help("More actions for \(profile.name)")
            .accessibilityLabel("More actions for \(profile.name)")
        }
        .padding(.vertical, 4)
        .contextMenu {
            Button("Delete Profile", role: .destructive) {
                confirmingDelete = true
            }
            .disabled(model.activeProfileID == profile.id || profileOperationInProgress)
        }
        .confirmationDialog(
            "Delete \(profile.name)?",
            isPresented: $confirmingDelete
        ) {
            Button("Delete Profile", role: .destructive) {
                Task { await model.removeProfile(profile.id) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the stored profile from MClash. The subscription itself is not changed.")
        }
    }

    private var originLabel: String {
        switch profile.origin {
        case .local: "Local profile"
        case let .imported(fileName): "Imported from \(fileName)"
        case let .remote(remote):
            if let updatedAt = remote.lastSuccessfulUpdateAt {
                "Subscription · Updated \(updatedAt.formatted(.relative(presentation: .named)))"
            } else {
                "Remote subscription"
            }
        }
    }

    private var profileOperationInProgress: Bool {
        model.networkStateTransitionInProgress
            || model.isPerforming(.activateProfile(profile.id))
            || model.isPerforming(.refreshProfile(profile.id))
            || model.isPerforming(.removeProfile(profile.id))
    }
}

private struct AddSubscriptionView: View {
    @Bindable var model: AppModel
    @Binding var isPresented: Bool
    @State private var name = ""
    @State private var address = ""
    @State private var submissionError: String?
    @State private var submissionTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Add Subscription")
                .font(.title2.weight(.semibold))

            Form {
                TextField("Name", text: $name)
                    .disabled(isSubmitting)
                    .accessibilityIdentifier("subscription.name")
                TextField("URL", text: $address)
                    .textContentType(.URL)
                    .disabled(isSubmitting)
                    .accessibilityIdentifier("subscription.url")
            }
            .formStyle(.grouped)

            if let submissionError {
                Label(submissionError, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("subscription.error")
            }

            HStack {
                if isSubmitting {
                    ProgressView()
                        .controlSize(.small)
                    Text("Downloading and checking profile…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("subscription.progress")
                }

                Spacer()
                Button("Cancel", role: .cancel) {
                    submissionTask?.cancel()
                    isPresented = false
                }
                .accessibilityIdentifier("subscription.cancel")
                Button("Add") {
                    submit()
                }
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("subscription.submit")
                .buttonStyle(.borderedProminent)
                .disabled(!canSubmit)
            }
        }
        .padding(24)
        .frame(width: 480)
        .interactiveDismissDisabled(isSubmitting)
        .onChange(of: name) { _, _ in submissionError = nil }
        .onChange(of: address) { _, _ in submissionError = nil }
        .onDisappear {
            submissionTask?.cancel()
        }
    }

    private var isSubmitting: Bool {
        submissionTask != nil || model.isPerforming(.addRemoteProfile)
    }

    private var normalizedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var validatedURL: URL? {
        guard let url = URL(string: address.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host != nil else {
            return nil
        }
        return url
    }

    private var canSubmit: Bool {
        !isSubmitting && !normalizedName.isEmpty && validatedURL != nil
    }

    private func submit() {
        guard canSubmit, let url = validatedURL else { return }
        submissionError = nil
        submissionTask = Task {
            do {
                try await model.addRemoteProfile(name: normalizedName, url: url)
                if !Task.isCancelled {
                    await MainActor.run {
                        isPresented = false
                    }
                }
            } catch is CancellationError {
                // The sheet is normally already dismissed by the cancel action.
            } catch {
                if !Task.isCancelled {
                    await MainActor.run {
                        submissionError = error.localizedDescription
                    }
                }
            }
            await MainActor.run { submissionTask = nil }
        }
    }
}
