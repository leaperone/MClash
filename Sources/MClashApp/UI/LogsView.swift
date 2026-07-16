import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct LogsView: View {
    @Bindable var model: AppModel
    @State private var searchText = ""
    @State private var sourceFilter: LogSourceFilter = .all
    @State private var followsLatest = true
    @State private var exportError: String?
    @State private var layout: LogsLayout = .wide
    @State private var pendingPresentationTask: Task<Void, Never>?
    @State private var pendingScrollTask: Task<Void, Never>?
    @State private var presentation = LogPresentationSnapshot.empty

    var body: some View {
        let snapshot = presentation

        ScrollViewReader { proxy in
            Group {
                if snapshot.allCount == 0 {
                    ContentUnavailableView(
                        "No logs yet",
                        systemImage: "text.alignleft",
                        description: Text(
                            "Core and supervisor messages will appear here after the first connection attempt."
                        )
                    )
                } else if snapshot.visibleLines.isEmpty {
                    ContentUnavailableView(
                        "No matching logs",
                        systemImage: "line.3.horizontal.decrease.circle",
                        description: Text(snapshot.emptyResultsDescription)
                    )
                } else {
                    List(snapshot.visibleLines) { line in
                        LogLineRow(line: line, compact: layout == .compact)
                            .id(line.id)
                    }
                    .listStyle(.inset)
                    .mclashListSurface()
                }
            }
            .navigationTitle("Logs")
            .searchable(text: $searchText, prompt: "Search log messages or sources")
            .safeAreaInset(edge: .bottom, spacing: 0) {
                statusBar(snapshot: snapshot)
            }
            .toolbar {
                ToolbarItem {
                    if layout == .wide {
                        Picker("Log Source", selection: $sourceFilter) {
                            ForEach(LogSourceFilter.allCases) { filter in
                                Text(filter.title).tag(filter)
                            }
                        }
                        .pickerStyle(.segmented)
                        .frame(minWidth: 220, idealWidth: 260, maxWidth: 300)
                        .accessibilityLabel("Filter logs by source")
                    } else {
                        Picker("Source", selection: $sourceFilter) {
                            ForEach(LogSourceFilter.allCases) { filter in
                                Text(filter.title).tag(filter)
                            }
                        }
                        .pickerStyle(.menu)
                        .help("Filter logs by source")
                    }
                }

                ToolbarItemGroup {
                    Button {
                        followsLatest.toggle()
                        if followsLatest {
                            scrollToLatest(snapshot.latestID, using: proxy)
                        } else {
                            pendingScrollTask?.cancel()
                            pendingScrollTask = nil
                        }
                    } label: {
                        Label(
                            followsLatest ? "Pause Following" : "Resume Following",
                            systemImage: followsLatest ? "pause.fill" : "arrow.down.to.line"
                        )
                    }
                    .help(followsLatest ? "Pause automatic log following" : "Resume automatic log following")
                    .accessibilityHint(
                        followsLatest
                            ? "New matching log entries will no longer move the list."
                            : "Moves to the newest matching entry and follows new entries."
                    )
                    .keyboardShortcut("l", modifiers: [.command, .shift])

                    Button {
                        exportFilteredLogs(snapshot.visibleLines)
                    } label: {
                        Label("Export Logs…", systemImage: "square.and.arrow.up")
                    }
                    .help("Export the currently filtered diagnostic log")
                    .disabled(snapshot.visibleLines.isEmpty)
                    .keyboardShortcut("e", modifiers: [.command, .shift])

                    Button(role: .destructive) {
                        model.clearLogs()
                    } label: {
                        Label("Clear Logs", systemImage: "trash")
                    }
                    .help("Clear all collected logs")
                    .disabled(model.logs.isEmpty)
                }
            }
            .onChange(of: model.logs.last?.id) { _, _ in
                schedulePresentationRefresh()
            }
            .onChange(of: snapshot.latestID) { _, latestID in
                guard followsLatest else { return }
                scrollToLatest(latestID, using: proxy)
            }
            .onChange(of: sourceFilter) { _, _ in
                schedulePresentationRefresh()
            }
            .onChange(of: searchText) { _, _ in
                schedulePresentationRefresh()
            }
            .onAppear {
                refreshPresentation()
            }
        }
        .mclashPageSurface()
        .background {
            GeometryReader { geometry in
                Color.clear
                    .onAppear { updateLayout(geometry.size.width) }
                    .onChange(of: geometry.size.width) { _, width in
                        updateLayout(width)
                    }
            }
        }
        .onDisappear {
            pendingPresentationTask?.cancel()
            pendingPresentationTask = nil
            pendingScrollTask?.cancel()
            pendingScrollTask = nil
        }
        .alert(
            "Couldn’t Export Logs",
            isPresented: Binding(
                get: { exportError != nil },
                set: { isPresented in
                    if !isPresented { exportError = nil }
                }
            )
        ) {
            Button("OK", role: .cancel) { exportError = nil }
        } message: {
            Text(exportError ?? "The diagnostic log could not be saved.")
        }
    }

    private func statusBar(snapshot: LogPresentationSnapshot) -> some View {
        HStack(spacing: 10) {
            Text(
                "\(formattedCount(snapshot.visibleLines.count)) of "
                    + "\(formattedCount(snapshot.allCount)) entries"
            )
                .monospacedDigit()

            Spacer()

            Label(
                followsLatest ? "Following newest entry" : "Automatic following paused",
                systemImage: followsLatest ? "arrow.down.to.line" : "pause.circle"
            )
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
        .accessibilityElement(children: .combine)
    }

    private func scrollToLatest(_ latestID: UUID?, using proxy: ScrollViewProxy) {
        pendingScrollTask?.cancel()
        pendingScrollTask = nil
        guard let latestID else { return }
        pendingScrollTask = Task { @MainActor in
            await Task.yield()
            guard !Task.isCancelled, followsLatest else { return }
            proxy.scrollTo(latestID, anchor: .bottom)
            pendingScrollTask = nil
        }
    }

    @discardableResult
    private func refreshPresentation() -> UUID? {
        pendingPresentationTask?.cancel()
        pendingPresentationTask = nil
        let next = LogPresentationSnapshot(
            logs: model.logs,
            filter: sourceFilter,
            searchText: searchText
        )
        presentation = next
        return next.latestID
    }

    private func schedulePresentationRefresh() {
        guard pendingPresentationTask == nil else { return }
        pendingPresentationTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(80))
            guard !Task.isCancelled else { return }

            let next = LogPresentationSnapshot(
                logs: model.logs,
                filter: sourceFilter,
                searchText: searchText
            )
            presentation = next

            pendingPresentationTask = nil
            if next.sourceLatestID != model.logs.last?.id {
                schedulePresentationRefresh()
            }
        }
    }

    private func exportFilteredLogs(_ logs: [CoreLogLine]) {
        guard !logs.isEmpty else { return }

        let panel = NSSavePanel()
        panel.title = "Export Diagnostic Logs"
        panel.prompt = "Export"
        panel.canCreateDirectories = true
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = exportFileName()

        guard panel.runModal() == .OK, let destination = panel.url else { return }

        do {
            try exportText(for: logs).write(
                to: destination,
                atomically: true,
                encoding: .utf8
            )
        } catch {
            exportError = error.localizedDescription
        }
    }

    private func exportFileName() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        return "MClash-Diagnostics-\(formatter.string(from: Date())).log"
    }

    private func exportText(for logs: [CoreLogLine]) -> String {
        let timestampFormatter = ISO8601DateFormatter()
        timestampFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let header = [
            "# MClash diagnostic log",
            "# Exported: \(timestampFormatter.string(from: Date()))",
            "# Source filter: \(sourceFilter.title)",
            "# Search: \(query.isEmpty ? "None" : query)",
            "# Entries: \(logs.count)",
            ""
        ]

        let entries = logs.map { line in
            let timestamp = timestampFormatter.string(from: line.timestamp)
            let source = LogSourceFilter.title(for: line.stream)
            return "[\(timestamp)] [\(source)] \(line.message)"
        }
        return (header + entries).joined(separator: "\n") + "\n"
    }

    private func updateLayout(_ width: CGFloat) {
        let next = LogsLayout(width: width)
        if layout != next { layout = next }
    }
}

private enum LogsLayout: Equatable {
    case compact
    case wide

    init(width: CGFloat) {
        self = width < 680 ? .compact : .wide
    }
}

private struct LogPresentationSnapshot {
    static let empty = LogPresentationSnapshot(logs: [], filter: .all, searchText: "")

    let allCount: Int
    let visibleLines: [CoreLogLine]
    let latestID: UUID?
    let sourceLatestID: UUID?
    let emptyResultsDescription: String

    init(logs: [CoreLogLine], filter: LogSourceFilter, searchText: String) {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        allCount = logs.count
        sourceLatestID = logs.last?.id

        if filter == .all, query.isEmpty {
            visibleLines = logs
        } else {
            visibleLines = logs.filter { line in
                guard filter.includes(line.stream) else { return false }
                guard !query.isEmpty else { return true }
                return line.message.localizedCaseInsensitiveContains(query)
                    || LogSourceFilter.title(for: line.stream)
                        .localizedCaseInsensitiveContains(query)
            }
        }

        latestID = visibleLines.last?.id
        if query.isEmpty {
            emptyResultsDescription = "No \(filter.title) entries are currently available."
        } else {
            emptyResultsDescription = "No \(filter.title) entries contain “\(query)”."
        }
    }
}

private enum LogSourceFilter: String, CaseIterable, Identifiable {
    case all
    case stdout
    case stderr
    case supervisor

    var id: Self { self }

    var title: String {
        switch self {
        case .all: "All"
        case .stdout: "stdout"
        case .stderr: "stderr"
        case .supervisor: "supervisor"
        }
    }

    func includes(_ stream: CoreLogLine.Stream) -> Bool {
        switch self {
        case .all: true
        case .stdout: stream == .standardOutput
        case .stderr: stream == .standardError
        case .supervisor: stream == .supervisor
        }
    }

    static func title(for stream: CoreLogLine.Stream) -> String {
        switch stream {
        case .standardOutput: "stdout"
        case .standardError: "stderr"
        case .supervisor: "supervisor"
        }
    }
}

private struct LogLineRow: View {
    let line: CoreLogLine
    let compact: Bool

    var body: some View {
        Group {
            if compact {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 10) {
                        Label(sourceTitle, systemImage: sourceSymbol)
                            .foregroundStyle(sourceColor)
                        Text(line.timestamp, format: .dateTime.hour().minute().second())
                            .monospacedDigit()
                            .foregroundStyle(.tertiary)
                    }
                    .font(.caption)

                    Text(line.message)
                        .font(.system(.body, design: .monospaced))
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(line.timestamp, format: .dateTime.hour().minute().second())
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.tertiary)
                        .frame(width: 72, alignment: .trailing)

                    Label(sourceTitle, systemImage: sourceSymbol)
                        .font(.caption)
                        .foregroundStyle(sourceColor)
                        .frame(width: 94, alignment: .leading)

                    Text(line.message)
                        .font(.system(.body, design: .monospaced))
                        .fixedSize(horizontal: false, vertical: true)

                    Spacer(minLength: 0)
                }
            }
        }
        .padding(.vertical, compact ? 5 : 2)
        .textSelection(.enabled)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityDescription)
    }

    private var sourceTitle: String {
        LogSourceFilter.title(for: line.stream)
    }

    private var sourceSymbol: String {
        switch line.stream {
        case .standardOutput: "terminal"
        case .standardError: "exclamationmark.triangle.fill"
        case .supervisor: "gearshape"
        }
    }

    private var sourceColor: Color {
        switch line.stream {
        case .standardOutput: .secondary
        case .standardError: .red
        case .supervisor: Color(nsColor: .systemBlue)
        }
    }

    private var accessibilityDescription: String {
        let timestamp = line.timestamp.formatted(.dateTime.hour().minute().second())
        let semanticSource = line.stream == .standardError ? "stderr error" : sourceTitle
        return "\(timestamp), \(semanticSource), \(line.message)"
    }
}
