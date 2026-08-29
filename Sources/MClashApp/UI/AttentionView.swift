import SwiftUI

/// A durable, multi-subsystem view of everything that currently needs the
/// user's attention. Unlike the transient banner, simultaneous failures remain
/// visible and retain their own recovery action.
struct AttentionView: View {
    @Bindable var model: AppModel
    @State private var pendingIssueID: String?

    var body: some View {
        Group {
            if model.operationalIssues.isEmpty {
                ContentUnavailableView {
                    Label("Everything Looks Good", systemImage: "checkmark.circle.fill")
                } description: {
                    Text("MClash has no active operational issues. Live status remains visible in Overview.")
                } actions: {
                    Button("Back to Overview") { model.selection = .overview }
                        .buttonStyle(.borderedProminent)
                }
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(activeIssueTitle)
                                .font(.title2.weight(.semibold))
                            Text("Start with the first item. Technical details are available when needed.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.bottom, 4)

                        ForEach(Array(model.operationalIssues.enumerated()), id: \.element.id) { index, issue in
                            OperationalIssueCard(
                                issue: issue,
                                isPrimary: index == 0,
                                isWorking: pendingIssueID == issue.id,
                                actionsDisabled: pendingIssueID != nil
                            ) { action in
                                perform(action, for: issue.id)
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
        .toolbar {
            ToolbarItem {
                Button {
                    model.selection = .logs
                } label: {
                    Label("View Logs", systemImage: "text.alignleft")
                }
            }
        }
    }

    private var activeIssueTitle: String {
        let count = model.operationalIssues.count
        return AppLocalization.format(
            count == 1 ? "%@ active issue" : "%@ active issues",
            formattedCount(count)
        )
    }

    private func perform(_ action: OperationalIssue.Action, for issueID: String) {
        switch action {
        case .reconnect:
            guard pendingIssueID == nil else { return }
            pendingIssueID = issueID
            Task {
                if model.isConnected || model.isBusy {
                    await model.restartConnection()
                } else {
                    await model.connect()
                }
                pendingIssueID = nil
            }
        case .restoreSystemProxy:
            guard pendingIssueID == nil else { return }
            pendingIssueID = issueID
            Task {
                await model.disableSystemProxy()
                pendingIssueID = nil
            }
        case .retryAppRouting:
            guard pendingIssueID == nil else { return }
            pendingIssueID = issueID
            Task {
                await model.retryNetworkCaptureActivation()
                pendingIssueID = nil
            }
        case .openAppRouting:
            model.selection = .appRouting
        case .openRules:
            model.selection = .rules
        case .openProviders:
            model.selection = .providers
        case .openTraffic:
            model.selection = .connections
        case .openLogs:
            model.selection = .logs
        }
    }
}

private struct OperationalIssueCard: View {
    let issue: OperationalIssue
    let isPrimary: Bool
    let isWorking: Bool
    let actionsDisabled: Bool
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
                    Text(issue.localizedTitle)
                        .font(.headline)
                    Text(issue.subsystem.localizedTitle)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(.quaternary, in: Capsule())
                }

                Text(issue.localizedConsequence)
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

                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) { issueActions }
                    VStack(alignment: .leading, spacing: 8) { issueActions }
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
        .accessibilityLabel(
            AppLocalization.format(
                "%@. %@. %@",
                severityTitle,
                issue.localizedTitle,
                issue.localizedConsequence
            )
        )
    }

    @ViewBuilder
    private var issueActions: some View {
        if let title = issue.localizedPrimaryActionTitle,
           let action = issue.primaryAction {
            if isPrimary {
                actionButton(title: title, action: action)
                    .buttonStyle(.borderedProminent)
            } else {
                actionButton(title: title, action: action)
                    .buttonStyle(.bordered)
            }
        }
        if let title = issue.localizedSecondaryActionTitle,
           let action = issue.secondaryAction {
            Button(title) { perform(action) }
                .disabled(actionsDisabled)
        }
    }

    private func actionButton(
        title: String,
        action: OperationalIssue.Action
    ) -> some View {
        Button {
            perform(action)
        } label: {
            if isWorking {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Working…")
                }
            } else {
                Text(title)
            }
        }
        .disabled(actionsDisabled)
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

    private var severityTitle: String {
        switch issue.severity {
        case .error: AppLocalization.string("Error")
        case .warning: AppLocalization.string("Warning")
        case .information: AppLocalization.string("Information")
        }
    }
}
