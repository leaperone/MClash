import SwiftUI

struct ProxiesView: View {
    @Bindable var model: AppModel

    var body: some View {
        Group {
            if !model.isConnected {
                ContentUnavailableView(
                    "Connect to view proxies",
                    systemImage: "point.3.connected.trianglepath.dotted",
                    description: Text("Proxy groups are read from the active Alpha core at runtime.")
                )
            } else if model.proxyGroups.isEmpty {
                ContentUnavailableView(
                    "No selectable groups",
                    systemImage: "tray",
                    description: Text("The active configuration did not expose a selectable proxy group.")
                )
            } else {
                List {
                    Section("Routing") {
                        Picker("Mode", selection: modeBinding) {
                            Text("Rule").tag("rule")
                            Text("Global").tag("global")
                            Text("Direct").tag("direct")
                        }
                        .pickerStyle(.segmented)

                        Toggle("Use macOS system proxy", isOn: systemProxyBinding)
                    }

                    ForEach(model.proxyGroups, id: \.name) { group in
                        Section(group.name) {
                            Picker("Selected node", selection: proxyBinding(for: group)) {
                                ForEach(group.all, id: \.self) { proxy in
                                    Text(proxy).tag(Optional(proxy))
                                }
                            }
                            .labelsHidden()
                        }
                    }
                }
            }
        }
        .navigationTitle("Proxies")
    }

    private var modeBinding: Binding<String> {
        Binding(
            get: { model.runtimeConfig?.mode ?? "rule" },
            set: { mode in Task { await model.setMode(mode) } }
        )
    }

    private var systemProxyBinding: Binding<Bool> {
        Binding(
            get: { model.systemProxyEnabled },
            set: { _ in Task { await model.toggleSystemProxy() } }
        )
    }

    private func proxyBinding(for group: MihomoProxy) -> Binding<String?> {
        Binding(
            get: { group.now },
            set: { proxy in
                guard let proxy else { return }
                Task { await model.selectProxy(group: group.name, proxy: proxy) }
            }
        )
    }
}
