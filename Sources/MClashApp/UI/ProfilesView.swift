import SwiftUI

struct ProfilesView: View {
    @Bindable var model: AppModel
    @State private var showingSubscriptionSheet = false

    var body: some View {
        Group {
            if model.profiles.isEmpty {
                emptyState
            } else {
                List(model.profiles) { profile in
                    ProfileRow(model: model, profile: profile)
                }
                .listStyle(.inset)
            }
        }
        .navigationTitle("Profiles")
        .toolbar {
            ToolbarItemGroup {
                Button {
                    Task { await model.importProfile() }
                } label: {
                    if model.isPerforming(.importProfile) {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Label("Import YAML", systemImage: "square.and.arrow.down")
                    }
                }
                .disabled(!model.canPerform(.importProfile))
                .help("Import a local YAML profile")
                .accessibilityLabel(
                    model.isPerforming(.importProfile) ? "Importing YAML profile" : "Import YAML profile"
                )

                Button {
                    showingSubscriptionSheet = true
                } label: {
                    Label("Add Subscription", systemImage: "link.badge.plus")
                }
                .disabled(!model.canPerform(.addRemoteProfile))
                .help("Add a profile subscription")
            }
        }
        .sheet(isPresented: $showingSubscriptionSheet) {
            AddSubscriptionView(model: model, isPresented: $showingSubscriptionSheet)
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No Profiles", systemImage: "doc.badge.plus")
        } description: {
            Text("Import a local YAML configuration or add a subscription to get started.")
        } actions: {
            HStack(spacing: 10) {
                Button {
                    Task { await model.importProfile() }
                } label: {
                    if model.isPerforming(.importProfile) {
                        HStack(spacing: 7) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Importing…")
                        }
                    } else {
                        Label("Import YAML…", systemImage: "square.and.arrow.down")
                    }
                }
                .disabled(!model.canPerform(.importProfile))

                Button {
                    showingSubscriptionSheet = true
                } label: {
                    Label("Add Subscription…", systemImage: "link.badge.plus")
                }
                .buttonStyle(.borderedProminent)
                .disabled(!model.canPerform(.addRemoteProfile))
            }
        }
    }
}

private struct ProfileRow: View {
    @Bindable var model: AppModel
    let profile: ProfileMetadata
    @State private var confirmingDelete = false
    @State private var operationError: String?

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            activeIndicator

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(profile.name)
                        .font(.body.weight(isActive ? .semibold : .regular))
                        .lineLimit(1)
                        .help(profile.name)

                    if isActive {
                        Label("Active", systemImage: "checkmark")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.tint)
                    }
                }

                HStack(spacing: 10) {
                    Label(originTitle, systemImage: originSymbol)
                    Text("•")
                        .accessibilityHidden(true)
                    Text(lastUpdatedTitle)
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                if let operationTitle {
                    HStack(spacing: 7) {
                        ProgressView()
                            .controlSize(.small)
                        Text(operationTitle)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityElement(children: .combine)
                } else if let operationError {
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                            .accessibilityHidden(true)
                        Text(operationError)
                            .lineLimit(2)
                        Button("Dismiss") { self.operationError = nil }
                            .buttonStyle(.borderless)
                            .controlSize(.small)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityElement(children: .contain)
                }
            }

            Spacer(minLength: 18)

            HStack(spacing: 8) {
                if isRemote {
                    Button {
                        refresh()
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .disabled(!model.canPerform(.refreshProfile(profile.id)))
                    .help("Refresh \(profile.name) subscription")
                }

                if isActive {
                    Text("In Use")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 64)
                        .accessibilityLabel("\(profile.name) is the active profile")
                } else {
                    Button("Activate") {
                        activate()
                    }
                    .buttonStyle(.bordered)
                    .disabled(!model.canPerform(.activateProfile(profile.id)))
                    .help("Activate \(profile.name)")
                }

                Button("Delete", systemImage: "trash", role: .destructive) {
                    confirmingDelete = true
                }
                .buttonStyle(.borderless)
                .disabled(isActive || !model.canPerform(.removeProfile(profile.id)))
                .help(isActive ? "Activate another profile before deleting this one" : "Delete \(profile.name)")
            }
            .controlSize(.small)
        }
        .padding(.vertical, 7)
        .accessibilityElement(children: .contain)
        .confirmationDialog(
            "Delete \(profile.name)?",
            isPresented: $confirmingDelete
        ) {
            Button("Delete Profile", role: .destructive) {
                remove()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the stored profile from MClash. The subscription itself is not changed.")
        }
    }

    private var activeIndicator: some View {
        Image(systemName: isActive ? "checkmark.circle.fill" : originSymbol)
            .font(.title3)
            .foregroundStyle(isActive ? Color.accentColor : .secondary)
            .frame(width: 24)
            .accessibilityHidden(true)
    }

    private var isActive: Bool {
        model.activeProfileID == profile.id
    }

    private var isRemote: Bool {
        if case .remote = profile.origin { return true }
        return false
    }

    private var originTitle: String {
        switch profile.origin {
        case .local:
            "Local"
        case let .imported(fileName):
            "Imported from \(fileName)"
        case .remote:
            "Subscription"
        }
    }

    private var originSymbol: String {
        switch profile.origin {
        case .local: "doc"
        case .imported: "square.and.arrow.down"
        case .remote: "link"
        }
    }

    private var lastUpdatedTitle: String {
        switch profile.origin {
        case let .remote(remote):
            if let updatedAt = remote.lastSuccessfulUpdateAt {
                return "Updated \(relativeDate(updatedAt))"
            }
            if let checkedAt = remote.lastCheckedAt {
                return "Checked \(relativeDate(checkedAt)) · No update yet"
            }
            return "Not updated yet"
        case .local, .imported:
            return "Updated \(relativeDate(profile.updatedAt))"
        }
    }

    private var operationTitle: String? {
        if model.isPerforming(.refreshProfile(profile.id)) { return "Refreshing and validating…" }
        if model.isPerforming(.activateProfile(profile.id)) { return "Activating and checking…" }
        if model.isPerforming(.removeProfile(profile.id)) { return "Deleting…" }
        return nil
    }

    private func relativeDate(_ date: Date) -> String {
        date.formatted(.relative(presentation: .named))
    }

    private func activate() {
        operationError = nil
        Task {
            do {
                try await model.activateProfile(profile.id)
            } catch {
                let message = sanitizedError(error.localizedDescription)
                operationError = message
                model.errorMessage = message
            }
        }
    }

    private func refresh() {
        operationError = nil
        let previousError = model.errorMessage
        Task {
            await model.refreshProfile(profile.id)
            if let message = model.errorMessage, message != previousError {
                let sanitized = sanitizedError(message)
                operationError = sanitized
                model.errorMessage = sanitized
            }
        }
    }

    private func remove() {
        operationError = nil
        let previousError = model.errorMessage
        Task {
            await model.removeProfile(profile.id)
            if let message = model.errorMessage, message != previousError {
                let sanitized = sanitizedError(message)
                operationError = sanitized
                model.errorMessage = sanitized
            }
        }
    }

    private func sanitizedError(_ message: String) -> String {
        guard case let .remote(remote) = profile.origin else { return message }
        return redact(remote.url, from: message)
    }

    private func redact(_ url: URL, from message: String) -> String {
        var sanitized = message.replacingOccurrences(
            of: url.absoluteString,
            with: "the subscription endpoint",
            options: .caseInsensitive
        )
        if let host = url.host, !host.isEmpty {
            sanitized = sanitized.replacingOccurrences(
                of: host,
                with: "the subscription host",
                options: .caseInsensitive
            )
        }
        return sanitized
    }
}

private struct AddSubscriptionView: View {
    private enum Field: Hashable {
        case name
        case address
    }

    @Bindable var model: AppModel
    @Binding var isPresented: Bool
    @State private var name = ""
    @State private var address = ""
    @State private var submissionError: String?
    @State private var submissionTask: Task<Void, Never>?
    @State private var attemptedSubmission = false
    @FocusState private var focusedField: Field?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Label("Add Subscription", systemImage: "link.badge.plus")
                    .font(.title2.weight(.semibold))
                Text("MClash will download, validate, and activate the profile before adding it.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Form {
                Section {
                    VStack(alignment: .leading, spacing: 5) {
                        TextField("Name", text: $name)
                            .focused($focusedField, equals: .name)
                            .submitLabel(.next)
                            .onSubmit { focusedField = .address }
                            .disabled(isSubmitting)
                            .accessibilityIdentifier("subscription.name")

                        if let nameValidationMessage {
                            validationLabel(nameValidationMessage)
                                .accessibilityIdentifier("subscription.name.error")
                        }
                    }

                    VStack(alignment: .leading, spacing: 5) {
                        TextField("Subscription URL", text: $address)
                            .textContentType(.URL)
                            .privacySensitive()
                            .focused($focusedField, equals: .address)
                            .submitLabel(.done)
                            .onSubmit { submit() }
                            .disabled(isSubmitting)
                            .accessibilityIdentifier("subscription.url")

                        if let addressValidationMessage {
                            validationLabel(addressValidationMessage)
                                .accessibilityIdentifier("subscription.url.error")
                        }
                    }
                }
            }
            .formStyle(.grouped)

            if let submissionError {
                Label(submissionError, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("subscription.error")
            } else if !isSubmitting, !model.canPerform(.addRemoteProfile) {
                Label(
                    "Finish the current network or profile operation before adding this subscription.",
                    systemImage: "clock"
                )
                .font(.callout)
                .foregroundStyle(.secondary)
            }

            HStack(spacing: 10) {
                if isSubmitting {
                    ProgressView()
                        .controlSize(.small)
                    Text("Downloading and validating profile…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("subscription.progress")
                }

                Spacer()

                Button("Cancel", role: .cancel) {
                    cancel()
                }
                .keyboardShortcut(.cancelAction)
                .accessibilityIdentifier("subscription.cancel")

                Button("Add") {
                    submit()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(!canSubmit)
                .accessibilityIdentifier("subscription.submit")
            }
        }
        .padding(24)
        .frame(width: 520)
        .interactiveDismissDisabled(isSubmitting)
        .onAppear { focusedField = .name }
        .onChange(of: name) { _, _ in
            submissionError = nil
        }
        .onChange(of: address) { _, _ in
            submissionError = nil
        }
        .onDisappear {
            submissionTask?.cancel()
        }
    }

    @ViewBuilder
    private func validationLabel(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.circle.fill")
            .font(.caption)
            .foregroundStyle(.red)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var isSubmitting: Bool {
        submissionTask != nil
    }

    private var normalizedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var normalizedAddress: String {
        address.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var validatedURL: URL? {
        guard let url = URL(string: normalizedAddress),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host?.isEmpty == false else {
            return nil
        }
        return url
    }

    private var nameValidationMessage: String? {
        guard attemptedSubmission, normalizedName.isEmpty else { return nil }
        return "Enter a name for this profile."
    }

    private var addressValidationMessage: String? {
        guard attemptedSubmission || !normalizedAddress.isEmpty else { return nil }
        if normalizedAddress.isEmpty { return "Enter the subscription address." }
        if validatedURL == nil { return "Use a complete HTTP or HTTPS address." }
        return nil
    }

    private var canSubmit: Bool {
        !isSubmitting
            && !normalizedName.isEmpty
            && validatedURL != nil
            && model.canPerform(.addRemoteProfile)
    }

    private func submit() {
        attemptedSubmission = true
        submissionError = nil

        guard !normalizedName.isEmpty else {
            focusedField = .name
            return
        }
        guard let url = validatedURL else {
            focusedField = .address
            return
        }
        guard model.canPerform(.addRemoteProfile), submissionTask == nil else {
            submissionError = "Another network or profile operation is still finishing. Try again in a moment."
            return
        }

        focusedField = nil
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
                    let message = sanitizedError(error.localizedDescription, url: url)
                    await MainActor.run {
                        submissionError = message
                    }
                }
            }
            await MainActor.run { submissionTask = nil }
        }
    }

    private func cancel() {
        submissionTask?.cancel()
        isPresented = false
    }

    private func sanitizedError(_ message: String, url: URL) -> String {
        var sanitized = message.replacingOccurrences(
            of: url.absoluteString,
            with: "the subscription endpoint",
            options: .caseInsensitive
        )
        if let host = url.host, !host.isEmpty {
            sanitized = sanitized.replacingOccurrences(
                of: host,
                with: "the subscription host",
                options: .caseInsensitive
            )
        }
        return sanitized
    }
}
