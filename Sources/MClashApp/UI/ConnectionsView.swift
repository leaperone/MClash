import SwiftUI

struct ConnectionsView: View {
    @Bindable var model: AppModel

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
            } else {
                List(model.connections?.connections ?? []) { connection in
                    ConnectionRow(model: model, connection: connection)
                }
            }
        }
        .navigationTitle("Connections")
        .toolbar {
            Button("Close All") {
                Task { await model.closeAllConnections() }
            }
            .disabled(model.connections?.connections.isEmpty != false)
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
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .help("Close connection")
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
