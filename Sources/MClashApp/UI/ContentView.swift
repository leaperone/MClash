import SwiftUI

struct ContentView: View {
    @Bindable var model: AppModel

    var body: some View {
        NavigationSplitView {
            List(AppModel.Destination.allCases, selection: $model.selection) { destination in
                Label(destination.title, systemImage: destination.symbol)
                    .tag(destination)
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 210, max: 240)
        } detail: {
            destinationView
        }
        .alert(
            "MClash could not complete the operation",
            isPresented: Binding(
                get: { model.errorMessage != nil },
                set: { if !$0 { model.errorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "Unknown error")
        }
    }

    @ViewBuilder
    private var destinationView: some View {
        switch model.selection ?? .overview {
        case .overview:
            OverviewView(model: model)
        case .proxies:
            ProxiesView(model: model)
        case .profiles:
            ProfilesView(model: model)
        case .connections:
            ConnectionsView(model: model)
        case .logs:
            LogsView(model: model)
        case .settings:
            SettingsView(model: model)
        }
    }
}
