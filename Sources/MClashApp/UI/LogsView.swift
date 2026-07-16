import SwiftUI

struct LogsView: View {
    @Bindable var model: AppModel

    var body: some View {
        Group {
            if model.logs.isEmpty {
                ContentUnavailableView(
                    "No logs yet",
                    systemImage: "text.alignleft",
                    description: Text("Core and supervisor messages will appear here after the first connection attempt.")
                )
            } else {
                ScrollViewReader { proxy in
                    List(model.logs) { line in
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            Text(line.timestamp, format: .dateTime.hour().minute().second())
                                .foregroundStyle(.tertiary)
                                .monospacedDigit()
                            Text(line.message)
                                .font(.system(.body, design: .monospaced))
                                .textSelection(.enabled)
                            Spacer(minLength: 0)
                        }
                        .id(line.id)
                    }
                    .onChange(of: model.logs.last?.id) { _, newValue in
                        guard let newValue else { return }
                        proxy.scrollTo(newValue, anchor: .bottom)
                    }
                }
            }
        }
        .navigationTitle("Logs")
        .toolbar {
            Button("Clear") { model.clearLogs() }
                .disabled(model.logs.isEmpty)
        }
    }
}
