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
                    .disabled(model.coreState == .validating || model.coreState == .stopping)
                }

                Divider()

                LabeledContent("Configuration") {
                    HStack(spacing: 10) {
                        Text(model.activeConfigURL?.lastPathComponent ?? "Not selected")
                            .foregroundStyle(model.activeConfigURL == nil ? .secondary : .primary)
                        Button("Choose…") { model.chooseConfiguration() }
                    }
                }

                LabeledContent("Core") {
                    HStack(spacing: 10) {
                        Text(coreLabel)
                            .foregroundStyle(model.explicitCoreURL == nil ? .secondary : .primary)
                        Button("Choose…") { model.chooseCoreBinary() }
                    }
                }

                if let session = model.runningSession {
                    Divider()
                    LabeledContent("Version", value: session.version)
                    LabeledContent("Controller", value: session.endpoint.absoluteString)
                    LabeledContent("Started", value: session.startedAt.formatted(date: .omitted, time: .standard))
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
            "Choose an Alpha core and configuration to start a local proxy session."
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

    private var coreLabel: String {
        model.explicitCoreURL?.lastPathComponent ?? "Bundled or Application Support core"
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
        case .validating, .starting, .stopping: .indigo
        case .stopped: .secondary
        }
    }
}
