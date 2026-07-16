import SwiftUI

struct ConnectionsView: View {
    @Bindable var model: AppModel
    @State private var searchText = ""
    @State private var debouncedSearchText = ""
    @State private var selectedConnectionID: String?
    @State private var sortOrder: [KeyPathComparator<ConnectionTableRow>] = []
    @State private var inspectorPresented = false

    var body: some View {
        let presentation = ConnectionPresentationSnapshot(
            snapshot: model.connections,
            searchText: debouncedSearchText,
            selectedConnectionID: selectedConnectionID,
            sortOrder: sortOrder
        )

        Group {
            if !model.isConnected {
                ContentUnavailableView(
                    "Connect to inspect traffic",
                    systemImage: "arrow.left.arrow.right",
                    description: Text("Live connections are streamed from the local Alpha controller.")
                )
            } else if !presentation.hasConnections {
                ContentUnavailableView(
                    "No active connections",
                    systemImage: "checkmark.circle",
                    description: Text("New network connections will appear here automatically.")
                )
            } else if presentation.rows.isEmpty {
                ContentUnavailableView.search(text: searchText)
            } else {
                connectionTable(rows: presentation.rows)
            }
        }
        .navigationTitle("Connections")
        .mclashPageSurface()
        .searchable(text: $searchText, prompt: "Host, process, rule, IP, or node")
        .inspector(isPresented: $inspectorPresented) {
            connectionInspector(presentation.selectedConnection)
                .inspectorColumnWidth(min: 280, ideal: 340, max: 440)
        }
        .task(id: searchText) {
            do {
                try await Task.sleep(for: .milliseconds(180))
                debouncedSearchText = searchText
            } catch {
                return
            }
        }
        .onChange(of: presentation.selectedConnectionIsVisible) { _, isVisible in
            guard selectedConnectionID != nil, !isVisible else { return }
            self.selectedConnectionID = nil
            inspectorPresented = false
        }
        .onChange(of: model.isConnected) { _, isConnected in
            if !isConnected {
                selectedConnectionID = nil
                inspectorPresented = false
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if model.errorMessage == nil,
               model.degradedStreams.contains(.connections) {
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
                .background(.bar)
                .overlay(alignment: .bottom) { Divider() }
            }
        }
        .toolbar {
            ToolbarItemGroup {
                Text(presentation.connectionCountLabel)
                    .foregroundStyle(.secondary)

                if let downloadTotal = presentation.downloadTotal,
                   let uploadTotal = presentation.uploadTotal {
                    Label(formattedByteCount(downloadTotal), systemImage: "arrow.down")
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .help("Session download")
                    Label(formattedByteCount(uploadTotal), systemImage: "arrow.up")
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .help("Session upload")
                }

                Button {
                    inspectorPresented.toggle()
                } label: {
                    Label("Connection Inspector", systemImage: "sidebar.right")
                }
                .disabled(presentation.selectedConnection == nil)
                .help(inspectorPresented ? "Hide Connection Inspector" : "Show Connection Inspector")

                Button {
                    Task { await model.closeAllConnections() }
                } label: {
                    if model.isPerforming(.closeAllConnections) {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Label("Close All", systemImage: "xmark.circle")
                    }
                }
                .disabled(
                    !presentation.hasConnections
                        || !model.canPerform(.closeAllConnections)
                )
                .help("Close every active connection")
            }
        }
    }

    private func connectionTable(rows: [ConnectionTableRow]) -> some View {
        Table(rows, selection: $selectedConnectionID, sortOrder: $sortOrder) {
            TableColumn("Destination", value: \.destination) { row in
                Text(row.destination)
                    .lineLimit(1)
                    .help(row.destination)
            }
            .width(min: 170, ideal: 240, max: 360)

            TableColumn("Process", value: \.process) { row in
                Text(row.process)
                    .lineLimit(1)
                    .foregroundStyle(.secondary)
                    .help(row.process)
            }
            .width(min: 90, ideal: 140, max: 220)

            TableColumn("Node / Chain", value: \.chain) { row in
                Text(row.chain)
                    .lineLimit(1)
                    .help(row.fullChain)
            }
            .width(min: 110, ideal: 170, max: 280)

            TableColumn("Rule", value: \.rule) { row in
                Text(row.rule)
                    .lineLimit(1)
                    .foregroundStyle(.secondary)
                    .help(row.ruleHelp)
            }
            .width(min: 90, ideal: 140, max: 240)

            TableColumn("Download", value: \.download) { row in
                Text(formattedByteCount(row.download))
                    .monospacedDigit()
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 82, ideal: 92, max: 120)

            TableColumn("Upload", value: \.upload) { row in
                Text(formattedByteCount(row.upload))
                    .monospacedDigit()
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 82, ideal: 92, max: 120)

            TableColumn("") { row in
                Button {
                    Task { await model.closeConnection(row.id) }
                } label: {
                    if model.isPerforming(.closeConnection(row.id)) {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "xmark")
                    }
                }
                .buttonStyle(.borderless)
                .disabled(
                    model.isPerforming(.closeAllConnections)
                        || !model.canPerform(.closeConnection(row.id))
                )
                .help("Close connection to \(row.destination)")
                .accessibilityLabel("Close connection to \(row.destination)")
            }
            .width(32)
        }
        .accessibilityLabel("Active connections")
    }

    @ViewBuilder
    private func connectionInspector(_ connection: MihomoConnection?) -> some View {
        if let connection {
            ConnectionDetailView(model: model, connection: connection)
        } else {
            ContentUnavailableView(
                "Select a connection",
                systemImage: "sidebar.right",
                description: Text("Choose a row to inspect its route, process, addresses, and metadata.")
            )
        }
    }
}

private struct ConnectionPresentationSnapshot {
    let rows: [ConnectionTableRow]
    let selectedConnection: MihomoConnection?
    let totalConnectionCount: Int
    let downloadTotal: Int64?
    let uploadTotal: Int64?
    let isFiltering: Bool
    let selectedConnectionIDWasNil: Bool

    init(
        snapshot: MihomoConnectionSnapshot?,
        searchText: String,
        selectedConnectionID: String?,
        sortOrder: [KeyPathComparator<ConnectionTableRow>]
    ) {
        let connections = snapshot?.connections ?? []
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let isFiltering = !query.isEmpty
        var rows: [ConnectionTableRow] = []
        rows.reserveCapacity(connections.count)
        var selectedConnection: MihomoConnection?

        for connection in connections {
            let row = ConnectionTableRow(connection)
            guard !isFiltering || connectionMatchesSearch(connection, row: row, query: query) else {
                continue
            }
            rows.append(row)
            if connection.id == selectedConnectionID {
                selectedConnection = connection
            }
        }

        // AppModel already publishes connections in newest-first order. Only apply another
        // sort when the user explicitly selects a Table sort descriptor.
        if !sortOrder.isEmpty {
            rows.sort(using: sortOrder)
        }

        self.rows = rows
        self.selectedConnection = selectedConnection
        totalConnectionCount = connections.count
        downloadTotal = snapshot?.downloadTotal
        uploadTotal = snapshot?.uploadTotal
        self.isFiltering = isFiltering
        selectedConnectionIDWasNil = selectedConnectionID == nil
    }

    var hasConnections: Bool {
        totalConnectionCount > 0
    }

    var selectedConnectionIsVisible: Bool {
        selectedConnectionIDWasNil || selectedConnection != nil
    }

    var connectionCountLabel: String {
        if !isFiltering {
            return "\(formattedCount(totalConnectionCount)) active"
        }
        return "\(formattedCount(rows.count)) of \(formattedCount(totalConnectionCount)) active"
    }
}

private struct ConnectionTableRow: Identifiable {
    let connection: MihomoConnection
    let destination: String
    let process: String
    let chain: String
    let rule: String
    let download: Int64
    let upload: Int64
    let start: String

    var id: String { connection.id }

    init(_ connection: MihomoConnection) {
        self.connection = connection
        destination = connectionDestination(connection)
        process = nonEmpty(connection.metadata.process) ?? "—"
        chain = connection.chains.first
            ?? nonEmpty(connection.metadata.specialProxy)
            ?? "—"
        rule = nonEmpty(connection.rule) ?? "—"
        download = connection.download
        upload = connection.upload
        start = connection.start
    }

    var fullChain: String {
        connection.chains.isEmpty ? chain : connection.chains.joined(separator: " → ")
    }

    var ruleHelp: String {
        guard let payload = nonEmpty(connection.rulePayload) else { return rule }
        return "\(rule) · \(payload)"
    }
}

private struct ConnectionDetailView: View {
    @Bindable var model: AppModel
    let connection: MihomoConnection

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(connectionDestination(connection))
                        .font(.headline)
                        .lineLimit(2)
                        .textSelection(.enabled)
                    Text(connectionSubtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 8)

                Button {
                    Task { await model.closeConnection(connection.id) }
                } label: {
                    if model.isPerforming(.closeConnection(connection.id)) {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Label("Close", systemImage: "xmark")
                    }
                }
                .disabled(
                    model.isPerforming(.closeAllConnections)
                        || !model.canPerform(.closeConnection(connection.id))
                )
                .help("Close this connection")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    ConnectionDetailSection("Traffic") {
                        ConnectionDetailRow(
                            "Download",
                            value: formattedByteCount(connection.download),
                            monospaced: true
                        )
                        ConnectionDetailRow(
                            "Upload",
                            value: formattedByteCount(connection.upload),
                            monospaced: true
                        )
                        ConnectionDetailRow(
                            "Total",
                            value: formattedByteCount(totalTraffic),
                            monospaced: true
                        )
                    }

                    ConnectionDetailSection("Routing") {
                        ConnectionDetailRow(
                            "Chain",
                            value: joined(connection.chains, separator: " → ")
                                ?? nonEmpty(connection.metadata.specialProxy)
                                ?? "—"
                        )
                        detailRow("Provider Chain", value: joined(connection.providerChains, separator: " → "))
                        ConnectionDetailRow("Rule", value: nonEmpty(connection.rule) ?? "—")
                        detailRow("Rule Payload", value: nonEmpty(connection.rulePayload))
                        detailRow("Special Proxy", value: nonEmpty(connection.metadata.specialProxy))
                        detailRow("Special Rules", value: nonEmpty(connection.metadata.specialRules))
                    }

                    ConnectionDetailSection("Destination") {
                        ConnectionDetailRow(
                            "Address",
                            value: destinationEndpoint ?? connectionDestination(connection),
                            monospaced: true
                        )
                        detailRow("Host", value: nonEmpty(connection.metadata.host))
                        detailRow("Sniffed Host", value: nonEmpty(connection.metadata.sniffHost))
                        detailRow("Remote", value: nonEmpty(connection.metadata.remoteDestination), monospaced: true)
                        detailRow("Location", value: joined(connection.metadata.destinationGeoIP, separator: " / "))
                        detailRow("ASN", value: nonEmpty(connection.metadata.destinationIPASN))
                    }

                    ConnectionDetailSection("Source") {
                        ConnectionDetailRow("Address", value: sourceEndpoint ?? "—", monospaced: true)
                        detailRow("Inbound", value: nonEmpty(connection.metadata.inboundName))
                        detailRow("Inbound Address", value: inboundEndpoint, monospaced: true)
                        detailRow("User", value: nonEmpty(connection.metadata.inboundUser))
                        if let uid = connection.metadata.uid {
                            ConnectionDetailRow("UID", value: String(uid), monospaced: true)
                        }
                        detailRow("Location", value: joined(connection.metadata.sourceGeoIP, separator: " / "))
                        detailRow("ASN", value: nonEmpty(connection.metadata.sourceIPASN))
                    }

                    ConnectionDetailSection("Process") {
                        ConnectionDetailRow("Name", value: nonEmpty(connection.metadata.process) ?? "Unavailable")
                        detailRow("Path", value: nonEmpty(connection.metadata.processPath), monospaced: true)
                    }
                }
                .padding(16)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Connection details for \(connectionDestination(connection))")
    }

    private var connectionSubtitle: String {
        let transport = [connection.metadata.network, connection.metadata.type]
            .compactMap(nonEmpty)
            .joined(separator: " · ")
        let started = formattedConnectionStart(connection.start)
        return [nonEmpty(transport), nonEmpty(started)]
            .compactMap { $0 }
            .joined(separator: " · ")
    }

    private var totalTraffic: Int64 {
        let (total, overflow) = connection.download.addingReportingOverflow(connection.upload)
        return overflow ? Int64.max : total
    }

    private var destinationEndpoint: String? {
        endpoint(
            address: nonEmpty(connection.metadata.destinationIP),
            port: nonEmpty(connection.metadata.destinationPort)
        )
    }

    private var sourceEndpoint: String? {
        endpoint(
            address: nonEmpty(connection.metadata.sourceIP),
            port: nonEmpty(connection.metadata.sourcePort)
        )
    }

    private var inboundEndpoint: String? {
        endpoint(
            address: nonEmpty(connection.metadata.inboundIP),
            port: nonEmpty(connection.metadata.inboundPort)
        )
    }

    @ViewBuilder
    private func detailRow(_ label: String, value: String?, monospaced: Bool = false) -> some View {
        if let value = nonEmpty(value) {
            ConnectionDetailRow(label, value: value, monospaced: monospaced)
        }
    }
}

private struct ConnectionDetailSection<Content: View>: View {
    let title: String
    let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.headline)
            VStack(alignment: .leading, spacing: 8) {
                content
            }
        }
    }
}

private struct ConnectionDetailRow: View {
    let label: String
    let value: String
    let monospaced: Bool

    init(_ label: String, value: String, monospaced: Bool = false) {
        self.label = label
        self.value = value
        self.monospaced = monospaced
    }

    var body: some View {
        LabeledContent {
            Text(value)
                .font(monospaced ? .callout.monospaced() : .callout)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
                .frame(maxWidth: 220, alignment: .trailing)
        } label: {
            Text(label)
                .foregroundStyle(.secondary)
        }
    }
}

private func connectionMatchesSearch(
    _ connection: MihomoConnection,
    row: ConnectionTableRow,
    query: String
) -> Bool {
    let metadata = connection.metadata

    func matches(_ value: String?) -> Bool {
        guard let value = nonEmpty(value) else { return false }
        return value.localizedCaseInsensitiveContains(query)
    }

    return row.destination.localizedCaseInsensitiveContains(query)
        || row.process.localizedCaseInsensitiveContains(query)
        || row.chain.localizedCaseInsensitiveContains(query)
        || row.rule.localizedCaseInsensitiveContains(query)
        || matches(metadata.host)
        || matches(metadata.sniffHost)
        || matches(metadata.destinationIP)
        || matches(metadata.destinationPort)
        || matches(metadata.remoteDestination)
        || matches(metadata.sourceIP)
        || matches(metadata.sourcePort)
        || matches(metadata.processPath)
        || matches(metadata.inboundName)
        || matches(metadata.inboundUser)
        || matches(metadata.network)
        || matches(metadata.type)
        || matches(connection.rulePayload)
        || matches(metadata.specialProxy)
        || matches(metadata.specialRules)
        || connection.chains.contains { $0.localizedCaseInsensitiveContains(query) }
        || connection.providerChains.contains { $0.localizedCaseInsensitiveContains(query) }
}

private func connectionDestination(_ connection: MihomoConnection) -> String {
    let metadata = connection.metadata
    let port = nonEmpty(metadata.destinationPort)
    if let host = nonEmpty(metadata.host) {
        return endpoint(address: host, port: port) ?? host
    }
    if let host = nonEmpty(metadata.sniffHost) {
        return endpoint(address: host, port: port) ?? host
    }
    if let address = nonEmpty(metadata.destinationIP) {
        return endpoint(address: address, port: port) ?? address
    }
    return nonEmpty(metadata.remoteDestination) ?? "Unknown destination"
}

private func endpoint(address: String?, port: String?) -> String? {
    guard let address = nonEmpty(address) else { return nil }
    guard let port = nonEmpty(port) else { return address }
    if address.contains(":"), !address.hasPrefix("[") {
        return "[\(address)]:\(port)"
    }
    return "\(address):\(port)"
}

private func nonEmpty(_ value: String?) -> String? {
    guard let value else { return nil }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
}

private func joined(_ values: [String]?, separator: String) -> String? {
    guard let values else { return nil }
    return nonEmpty(values.compactMap(nonEmpty).joined(separator: separator))
}

private func formattedConnectionStart(_ value: String) -> String {
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let date = fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    return date?.formatted(date: .abbreviated, time: .standard) ?? value
}
