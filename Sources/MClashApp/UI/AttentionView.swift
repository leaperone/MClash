import SwiftUI

/// A durable, multi-subsystem view of everything that currently needs the
/// user's attention. Unlike the transient banner, simultaneous failures remain
/// visible and retain their own recovery action.
struct AttentionView: View {
    @Bindable var model: AppModel

    var body: some View {
        Group {
            if model.operationalIssues.isEmpty {
                ContentUnavailableView(
                    "Everything Looks Good",
                    systemImage: "checkmark.circle.fill",
                    description: Text(
                        "MClash has no active operational issues. Live status remains visible in Overview."
                    )
                )
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        HStack(alignment: .firstTextBaseline) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("\(model.operationalIssues.count) active \(model.operationalIssues.count == 1 ? "issue" : "issues")")
                                    .font(.title2.weight(.semibold))
                                Text("Each item explains what is affected and how to recover it.")
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("View Logs") { model.selection = .logs }
                        }
                        .padding(.bottom, 4)

                        ForEach(model.operationalIssues) { issue in
                            OperationalIssueCard(issue: issue) { action in
                                perform(action)
                            }
                        }
                    }
                    .padding(.horizontal, MClashLayout.pagePadding)
                    .padding(.vertical, 24)
                    .frame(maxWidth: 900, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .top)
                }
            }
        }
        .navigationTitle("Attention")
        .mclashPageSurface()
    }

    private func perform(_ action: OperationalIssue.Action) {
        switch action {
        case .reconnect:
            Task {
                if model.isConnected || model.isBusy {
                    await model.restartConnection()
                } else {
                    await model.connect()
                }
            }
        case .restoreSystemProxy:
            Task { await model.disableSystemProxy() }
        case .retryAppRouting:
            Task { await model.retryNetworkCaptureActivation() }
        case .openAppRouting:
            model.selection = .appRouting
        case .openRules:
            model.selection = .rules
        case .openProviders:
            model.selection = .providers
        case .openLogs:
            model.selection = .logs
        }
    }
}

private struct OperationalIssueCard: View {
    let issue: OperationalIssue
    let perform: (OperationalIssue.Action) -> Void
    @State private var showsTechnicalDetail = false

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.title3.weight(.semibold))
                .foregroundStyle(color)
                .frame(width: 26, height: 26)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 8) {
                    Text(issue.title)
                        .font(.headline)
                    Text(issue.subsystem.rawValue)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(.quaternary, in: Capsule())
                }

                Text(issue.consequence)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if let technicalDetail = issue.technicalDetail,
                   !technicalDetail.isEmpty {
                    DisclosureGroup("Technical Details", isExpanded: $showsTechnicalDetail) {
                        Text(technicalDetail)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .padding(.top, 5)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .font(.caption)
                }

                HStack(spacing: 8) {
                    if let title = issue.primaryActionTitle,
                       let action = issue.primaryAction {
                        Button(title) { perform(action) }
                            .buttonStyle(.borderedProminent)
                    }
                    if let title = issue.secondaryActionTitle,
                       let action = issue.secondaryAction {
                        Button(title) { perform(action) }
                    }
                }
                .controlSize(.small)
                .padding(.top, 2)
            }

            Spacer(minLength: 0)
        }
        .padding(16)
        .background(
            Color(nsColor: .controlBackgroundColor),
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(color.opacity(0.25), lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
    }

    private var color: Color {
        switch issue.severity {
        case .error: .red
        case .warning: .orange
        case .information: .blue
        }
    }

    private var symbol: String {
        switch issue.severity {
        case .error: "exclamationmark.octagon.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .information: "info.circle.fill"
        }
    }
}
