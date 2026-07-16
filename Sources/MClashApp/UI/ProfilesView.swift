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
                        Button("Add Subscription…") { showingSubscriptionSheet = true }
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
        }
        .sheet(isPresented: $showingSubscriptionSheet) {
            AddSubscriptionView(model: model, isPresented: $showingSubscriptionSheet)
        }
    }
}

private struct ProfileRow: View {
    @Bindable var model: AppModel
    let profile: ProfileMetadata

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: model.activeProfileID == profile.id ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(model.activeProfileID == profile.id ? Color.accentColor : .secondary)

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
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Refresh subscription")
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
            .disabled(model.activeProfileID == profile.id)
        }
        .padding(.vertical, 4)
    }

    private var originLabel: String {
        switch profile.origin {
        case .local: "Local profile"
        case let .imported(fileName): "Imported from \(fileName)"
        case .remote: "Remote subscription"
        }
    }
}

private struct AddSubscriptionView: View {
    @Bindable var model: AppModel
    @Binding var isPresented: Bool
    @State private var name = ""
    @State private var address = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Add Subscription")
                .font(.title2.weight(.semibold))

            Form {
                TextField("Name", text: $name)
                TextField("URL", text: $address)
                    .textContentType(.URL)
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { isPresented = false }
                Button("Add") {
                    guard let url = URL(string: address) else { return }
                    Task {
                        await model.addRemoteProfile(
                            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                            url: url
                        )
                        if model.errorMessage == nil {
                            isPresented = false
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || URL(string: address) == nil)
            }
        }
        .padding(24)
        .frame(width: 480)
    }
}
