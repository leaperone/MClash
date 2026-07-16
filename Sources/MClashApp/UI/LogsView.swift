import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct LogsView: View {
    @Bindable var model: AppModel
    @State private var searchText = ""
    @State private var sourceFilter: LogSourceFilter = .all
    @State private var followsLatest = true
    @State private var exportError: String?

    var body: some View {
        ScrollViewReader { proxy in
            Group {
                if model.logs.isEmpty {
                    ContentUnavailableView(
                        "No logs yet",
                        systemImage: "text.alignleft",
                        description: Text(
                            "Core and supervisor messages will appear here after the first connection attempt."
                        )
                    )
                } else if filteredLogs.isEmpty {
                    ContentUnavailableView(
                        "No matching logs",
                        systemImage: "line.3.horizontal.decrease.circle",
                        description: Text(emptyResultsDescription)
                    )
                } else {
                    List(filteredLogs) { line in
                        LogLineRow(line: line)
                            .id(line.id)
                    }
                    .listStyle(.inset)
                    .mclashListSurface()
                }
            }
            .navigationTitle("Logs")
            .searchable(text: $searchText, prompt: "Search log messages or sources")
            .safeAreaInset(edge: .bottom, spacing: 0) {
                statusBar
            }
            .toolbar {
                ToolbarItem {
                    Picker("Log Source", selection: $sourceFilter) {
                        ForEach(LogSourceFilter.allCases) { filter in
                            Text(filter.title).tag(filter)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(minWidth: 180, idealWidth: 260, maxWidth: 330)
                    .accessibilityLabel("Filter logs by source")
                }

                ToolbarItemGroup {
                    Button {
                        followsLatest.toggle()
                        if followsLatest {
                            scrollToLatest(using: proxy)
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
                        exportFilteredLogs()
                    } label: {
                        Label("Export Logs…", systemImage: "square.and.arrow.up")
                    }
                    .help("Export the currently filtered diagnostic log")
                    .disabled(filteredLogs.isEmpty)
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
            .onChange(of: filteredLogs.last?.id) { _, _ in
                guard followsLatest else { return }
                scrollToLatest(using: proxy)
            }
            .onChange(of: sourceFilter) { _, _ in
                guard followsLatest else { return }
                scrollToLatest(using: proxy)
            }
            .onChange(of: searchText) { _, _ in
                guard followsLatest else { return }
                scrollToLatest(using: proxy)
            }
            .onAppear {
                guard followsLatest else { return }
                scrollToLatest(using: proxy)
            }
        }
        .mclashPageSurface()
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

    private var statusBar: some View {
        HStack(spacing: 10) {
            Text(
                "\(formattedCount(filteredLogs.count)) of "
                    + "\(formattedCount(model.logs.count)) entries"
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

    private var filteredLogs: [CoreLogLine] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return model.logs.filter { line in
            guard sourceFilter.includes(line.stream) else { return false }
            guard !query.isEmpty else { return true }
            return line.message.localizedCaseInsensitiveContains(query)
                || LogSourceFilter.title(for: line.stream).localizedCaseInsensitiveContains(query)
        }
    }

    private var emptyResultsDescription: String {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if query.isEmpty {
            return "No \(sourceFilter.title) entries are currently available."
        }
        return "No \(sourceFilter.title) entries contain “\(query)”."
    }

    private func scrollToLatest(using proxy: ScrollViewProxy) {
        guard let latestID = filteredLogs.last?.id else { return }
        Task { @MainActor in
            proxy.scrollTo(latestID, anchor: .bottom)
        }
    }

    private func exportFilteredLogs() {
        let logs = filteredLogs
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

    var body: some View {
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
        .padding(.vertical, 2)
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
