import SwiftUI

struct MenuBarContent: View {
    @Bindable var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("MClash")
                        .font(.headline)
                    Text(model.statusTitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Circle()
                    .fill(model.isConnected ? Color.green : Color.secondary.opacity(0.5))
                    .frame(width: 8, height: 8)
            }

            Button {
                Task { await model.toggleConnection() }
            } label: {
                Label(
                    model.isConnected ? "Disconnect" : "Connect",
                    systemImage: model.isConnected ? "stop.fill" : "play.fill"
                )
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.coreState == .validating || model.coreState == .stopping)

            Divider()

            Button("Open MClash") { openWindow(id: "main") }
            SettingsLink { Text("Settings…") }

            Divider()

            Button("Quit MClash") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q")
        }
        .padding(14)
        .frame(width: 260)
    }
}
