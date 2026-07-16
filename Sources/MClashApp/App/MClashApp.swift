import SwiftUI

@main
struct MClashApp: App {
    @NSApplicationDelegateAdaptor(ApplicationDelegate.self) private var applicationDelegate
    @State private var model = AppModel()

    var body: some Scene {
        Window("MClash", id: "main") {
            ContentView(model: model)
                .frame(minWidth: 860, minHeight: 560)
                .task {
                    applicationDelegate.shutdownHandler = { [weak model] in
                        await model?.shutdown()
                    }
                    await model.prepare()
                }
        }
        .defaultSize(width: 980, height: 680)

        MenuBarExtra {
            MenuBarContent(model: model)
        } label: {
            Label("MClash", systemImage: model.isConnected ? "network.badge.shield.half.filled" : "network")
        }

        Settings {
            SettingsView(model: model)
                .frame(width: 520, height: 320)
        }
    }
}
