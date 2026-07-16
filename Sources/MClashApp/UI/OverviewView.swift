import SwiftUI

struct OverviewView: View {
    @Bindable var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack(alignment: .center, spacing: 18) {
                    StatusMark(state: model.coreState)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(model.statusTitle)
                            .font(.title2.weight(.semibold))
                        Text(statusDescription)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Button {
                        Task { await model.toggleConnection() }
                    } label: {
                        Text(connectionButtonTitle)
                            .frame(minWidth: 92)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(!model.canPerform(.connection))
                }

                Divider()

                LabeledContent("Configuration") {
                    HStack(spacing: 10) {
                        Text(activeProfileName)
                            .foregroundStyle(model.activeProfileID == nil ? .secondary : .primary)
                            .lineLimit(1)
                            .help(activeProfileName)
                        Button("Manage Profiles") { model.selection = .profiles }
                    }
                }

                LabeledContent("Core") {
                    Text("mihomo Alpha · Included with MClash")
                        .foregroundStyle(.secondary)
                }

                if let session = model.runningSession {
                    if model.liveMetricsAreDegraded {
                        Label(
                            "Live traffic or connection data was interrupted and is reconnecting.",
                            systemImage: "arrow.clockwise"
                        )
                        .font(.callout)
                        .foregroundStyle(.orange)
                    }

                    Divider()
                    LabeledContent("Version", value: session.version)
                    LabeledContent("Controller", value: session.endpoint.absoluteString)
                    LabeledContent("Started", value: session.startedAt.formatted(date: .omitted, time: .standard))

                    Divider()

                    Grid(alignment: .leading, horizontalSpacing: 36, verticalSpacing: 10) {
                        GridRow {
                            Label("Download", systemImage: "arrow.down")
                                .foregroundStyle(.secondary)
                            Text(rate(model.traffic.download))
                                .monospacedDigit()
                            Label("Upload", systemImage: "arrow.up")
                                .foregroundStyle(.secondary)
                            Text(rate(model.traffic.upload))
                                .monospacedDigit()
                        }
                        GridRow {
                            Text("Routing Mode")
                                .foregroundStyle(.secondary)
                            Text((model.runtimeConfig?.mode ?? "—").capitalized)
                            Text("Connections")
                                .foregroundStyle(.secondary)
                            Text("\(model.connections?.connections.count ?? 0)")
                                .monospacedDigit()
                        }
                        GridRow {
                            Text("System Proxy")
                                .foregroundStyle(.secondary)
                            Text(model.systemProxyEnabled ? "On" : "Off")
                            Text("Session Traffic")
                                .foregroundStyle(.secondary)
                            Text(totalTraffic)
                                .monospacedDigit()
                        }
                    }
                }

                Spacer(minLength: 0)
            }
            .padding(32)
            .frame(maxWidth: 760, alignment: .leading)
        }
        .navigationTitle("Overview")
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var statusDescription: String {
        switch model.coreState {
        case .stopped:
            "Choose a profile to start a local proxy session with the bundled Alpha core."
        case .validating:
            "MClash is checking the active YAML with the core before applying it."
        case .starting:
            "The core is running its startup checks and opening the local controller."
        case let .running(session):
            "The local controller is healthy at \(session.endpoint.host() ?? "127.0.0.1")."
        case .stopping:
            "MClash is asking the core to shut down cleanly."
        case .failed:
            "Review the error and logs before trying again."
        }
    }

    private var connectionButtonTitle: String {
        switch model.coreState {
        case .running, .starting:
            "Disconnect"
        case .stopping:
            "Stopping…"
        case .validating:
            "Checking…"
        default:
            "Connect"
        }
    }

    private var activeProfileName: String {
        guard let activeProfileID = model.activeProfileID else { return "Not selected" }
        return model.profiles.first(where: { $0.id == activeProfileID })?.name ?? "Active profile"
    }

    private var totalTraffic: String {
        ByteCountFormatter.string(
            fromByteCount: model.traffic.uploadTotal + model.traffic.downloadTotal,
            countStyle: .file
        )
    }

    private func rate(_ bytes: Int64) -> String {
        "\(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))/s"
    }
}

private struct StatusMark: View {
    let state: CoreRunState

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 24, weight: .semibold))
            .foregroundStyle(color)
            .frame(width: 48, height: 48)
            .background(color.opacity(0.12), in: Circle())
            .accessibilityHidden(true)
    }

    private var symbol: String {
        switch state {
        case .running: "checkmark.shield.fill"
        case .failed: "exclamationmark.triangle.fill"
        case .validating, .starting, .stopping: "arrow.triangle.2.circlepath"
        case .stopped: "pause.fill"
        }
    }

    private var color: Color {
        switch state {
        case .running: .green
        case .failed: .red
        case .validating, .starting, .stopping: .orange
        case .stopped: .secondary
        }
    }
}
