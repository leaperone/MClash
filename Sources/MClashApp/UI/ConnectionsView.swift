import SwiftUI

struct ConnectionsView: View {
    @Bindable var model: AppModel
    @State private var searchText = ""
    @State private var debouncedSearchText = ""

    var body: some View {
        Group {
            if !model.isConnected {
                ContentUnavailableView(
                    "Connect to inspect traffic",
                    systemImage: "arrow.left.arrow.right",
                    description: Text("Live connections are streamed from the local Alpha controller.")
                )
            } else if model.connections?.connections.isEmpty != false {
                ContentUnavailableView(
                    "No active connections",
                    systemImage: "checkmark.circle",
                    description: Text("New network connections will appear here automatically.")
                )
            } else if filteredConnections.isEmpty {
                ContentUnavailableView.search(text: searchText)
            } else {
                List(filteredConnections) { connection in
                    ConnectionRow(model: model, connection: connection)
                }
            }
        }
        .navigationTitle("Connections")
        .searchable(text: $searchText, prompt: "Host, process, rule, or node")
        .task(id: searchText) {
            do {
                try await Task.sleep(for: .milliseconds(180))
                debouncedSearchText = searchText
            } catch {
                return
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if model.degradedStreams.contains(.connections) {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.clockwise")
                        .foregroundStyle(.orange)
                        .accessibilityHidden(true)
                    Text("Connection data is stale while the live stream reconnects.")
                        .font(.callout)
                    Spacer()
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Color(nsColor: .controlBackgroundColor))
                .overlay(alignment: .bottom) { Divider() }
            }
        }
        .toolbar {
            ToolbarItem {
                Text("\(model.connections?.connections.count ?? 0) active")
                    .foregroundStyle(.secondary)
            }
            ToolbarItem {
                Button {
                    Task { await model.closeAllConnections() }
                } label: {
                    if model.isPerforming(.closeAllConnections) {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Text("Close All")
                    }
                }
                .disabled(
                    model.connections?.connections.isEmpty != false
                        || model.networkStateTransitionInProgress
                )
            }
        }
    }

    private var filteredConnections: [MihomoConnection] {
        let connections = model.connections?.connections ?? []
        let query = debouncedSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return connections }
        return connections.filter { connection in
            connection.metadata.host?.localizedCaseInsensitiveContains(query) == true
                || connection.metadata.sniffHost?.localizedCaseInsensitiveContains(query) == true
                || connection.metadata.destinationIP?.localizedCaseInsensitiveContains(query) == true
                || connection.metadata.process?.localizedCaseInsensitiveContains(query) == true
                || connection.rule.localizedCaseInsensitiveContains(query)
                || connection.chains.contains { $0.localizedCaseInsensitiveContains(query) }
        }
    }
}

private struct ConnectionRow: View {
    @Bindable var model: AppModel
    let connection: MihomoConnection

    var body: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(destination)
                    .lineLimit(1)
                HStack(spacing: 8) {
                    if let process = connection.metadata.process, !process.isEmpty {
                        Text(process)
                    }
                    if let chain = connection.chains.first {
                        Text(chain)
                    }
                    if !connection.rule.isEmpty {
                        Text(connection.rule)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                Text("↓ \(ByteCountFormatter.string(fromByteCount: connection.download, countStyle: .file))")
                Text("↑ \(ByteCountFormatter.string(fromByteCount: connection.upload, countStyle: .file))")
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)

            Button {
                Task { await model.closeConnection(connection.id) }
            } label: {
                if model.isPerforming(.closeConnection(connection.id)) {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: "xmark")
                }
            }
            .buttonStyle(.borderless)
            .help("Close connection")
            .accessibilityLabel("Close connection to \(destination)")
            .disabled(
                model.networkStateTransitionInProgress
                    || model.isPerforming(.closeConnection(connection.id))
            )
        }
        .padding(.vertical, 3)
    }

    private var destination: String {
        if let host = connection.metadata.host, !host.isEmpty { return host }
        if let host = connection.metadata.sniffHost, !host.isEmpty { return host }
        if let ip = connection.metadata.destinationIP {
            if let port = connection.metadata.destinationPort { return "\(ip):\(port)" }
            return ip
        }
        return "Unknown destination"
    }
}
