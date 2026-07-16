import AppKit
import SwiftUI

struct SettingsView: View {
    @Bindable var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Form {
            Section("Core") {
                LabeledContent("Distribution", value: "Bundled mihomo Alpha")
                LabeledContent("Version", value: model.runningSession?.version ?? "Verified during build")
                LabeledContent("Controller", value: controllerAddress)
                Text("The controller credential is generated in memory for each app launch. MClash does not request Keychain access when connecting.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Configuration") {
                LabeledContent("Active profile", value: activeProfileName)
                Button("Manage Profiles…") {
                    model.selection = .profiles
                    openWindow(id: "main")
                    NSApplication.shared.activate(ignoringOtherApps: true)
                }
            }

            Section("Connection") {
                Toggle("Enable macOS system proxy when connecting", isOn: $model.autoEnableSystemProxy)
                Toggle(
                    "Close existing connections after changing mode or node",
                    isOn: $model.closeConnectionsOnRoutingChange
                )
                Text("MClash uses the profile's HTTP and SOCKS5 ports, falling back to mixed-port when available.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if model.isConnected {
                    LabeledContent("HTTP", value: model.localHTTPProxyAddress ?? "Unavailable")
                    LabeledContent("SOCKS5", value: model.localSOCKSProxyAddress ?? "Unavailable")
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        .navigationTitle("Settings")
    }

    private var activeProfileName: String {
        guard let activeProfileID = model.activeProfileID else { return "None" }
        return model.profiles.first(where: { $0.id == activeProfileID })?.name ?? "Active profile"
    }

    private var controllerAddress: String {
        guard let endpoint = model.runningSession?.endpoint,
              let host = endpoint.host(),
              let port = endpoint.port else {
            return "Assigned automatically when connecting"
        }
        return "\(host):\(port)"
    }
}
