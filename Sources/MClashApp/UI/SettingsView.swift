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
                LabeledContent("Controller", value: "127.0.0.1:19090")
            }

            Section("Configuration") {
                LabeledContent("Active profile", value: activeProfileName)
                Button("Manage Profiles…") {
                    model.selection = .profiles
                    openWindow(id: "main")
                    NSApplication.shared.activate(ignoringOtherApps: true)
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private var activeProfileName: String {
        guard let activeProfileID = model.activeProfileID else { return "None" }
        return model.profiles.first(where: { $0.id == activeProfileID })?.name ?? "Active profile"
    }
}
