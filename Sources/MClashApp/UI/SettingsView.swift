import SwiftUI

struct SettingsView: View {
    @Bindable var model: AppModel

    var body: some View {
        Form {
            Section("Core") {
                LabeledContent("Binary") {
                    HStack {
                        Text(model.explicitCoreURL?.path(percentEncoded: false) ?? "Automatic")
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Button("Choose…") { model.chooseCoreBinary() }
                    }
                }

                LabeledContent("Controller", value: "127.0.0.1:19090")
            }

            Section("Configuration") {
                LabeledContent("Active file") {
                    HStack {
                        Text(model.activeConfigURL?.path(percentEncoded: false) ?? "None")
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Button("Choose…") { model.chooseConfiguration() }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}
