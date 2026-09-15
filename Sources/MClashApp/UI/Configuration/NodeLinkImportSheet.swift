import AppKit
import SwiftUI

struct NodeLinkImportSheet: View {
    @Bindable var model: AppModel
    @Binding var isPresented: Bool
    let initialText: String
    @State private var name = ""
    @State private var text: String
    @State private var isSubmitting = false
    @State private var errorMessage: String?
    @FocusState private var textFocused: Bool

    private var preview: NodeLinkImportPreview {
        model.previewNodeLinks(text)
    }

    init(model: AppModel, isPresented: Binding<Bool>, initialText: String = "") {
        self.model = model
        self._isPresented = isPresented
        self.initialText = initialText
        self._text = State(initialValue: initialText)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 5) {
                Label(AppLocalization.string("Add node links"), systemImage: "link.badge.plus")
                    .font(.title2.weight(.semibold))
                Text(AppLocalization.string("Paste share links or a WireGuard configuration. MClash will check them before adding nodes to your configuration."))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Button(AppLocalization.string("Read clipboard"), systemImage: "doc.on.clipboard") {
                    if let value = NSPasteboard.general.string(forType: .string) {
                        text = value
                        errorMessage = nil
                    }
                }
                .disabled(isSubmitting)
                Spacer()
                if !preview.detectedFormats.isEmpty {
                    Text(preview.detectedFormats.map(displayedFormat).joined(separator: ", "))
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
            }

            TextEditor(text: $text)
                .font(.body.monospaced())
                .focused($textFocused)
                .frame(minHeight: 150, idealHeight: 210)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.25)))
                .accessibilityIdentifier("node-links.input")

            Form {
                TextField(AppLocalization.string("Name (optional)"), text: $name)
                    .accessibilityIdentifier("node-links.name")
                if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Section(AppLocalization.string("Preview")) {
                        LabeledContent(AppLocalization.string("Usable nodes"), value: String(preview.nodes.count))
                        if preview.ignoredLines > 0 {
                            LabeledContent(AppLocalization.string("Ignored lines"), value: String(preview.ignoredLines))
                        }
                        ForEach(preview.nodes, id: \.id) { node in
                            HStack {
                                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(node.displayName).lineLimit(1)
                                    Text("\(node.proto.rawValue) · \(node.host):\(node.port)")
                                        .font(.caption.monospaced())
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        ForEach(Array(preview.diagnostics.enumerated()), id: \.offset) { _, diagnostic in
                            Label(diagnostic.message, systemImage: diagnostic.severity == .error ? "xmark.circle" : "info.circle")
                                .font(.caption)
                                .foregroundStyle(diagnostic.severity == .error ? .red : .orange)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .frame(maxHeight: 255)

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("node-links.error")
            }

            HStack(spacing: 10) {
                if isSubmitting {
                    ProgressView().controlSize(.small)
                    Text(AppLocalization.string("Adding nodes…")).font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button(AppLocalization.string("Cancel"), role: .cancel) {
                    model.cancelPendingNodeLinkImport()
                    isPresented = false
                }
                    .keyboardShortcut(.cancelAction)
                    .disabled(isSubmitting)
                Button(AppLocalization.string("Add nodes")) { submit() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(isSubmitting || preview.nodes.isEmpty)
                    .accessibilityIdentifier("node-links.submit")
            }
        }
        .padding(24)
        .frame(minWidth: 530, idealWidth: 650, maxWidth: 760, minHeight: 500)
        .onAppear { textFocused = true }
        .onChange(of: text) { _, _ in errorMessage = nil }
    }

    private func submit() {
        guard !isSubmitting else { return }
        isSubmitting = true
        errorMessage = nil
        Task {
            do {
                _ = try await model.importNodeLinks(name: name, text: text)
                model.cancelPendingNodeLinkImport()
                isPresented = false
            } catch {
                errorMessage = error.localizedDescription
            }
            isSubmitting = false
        }
    }

    private func displayedFormat(_ format: String) -> String {
        switch format {
        case "wireguard-config": return AppLocalization.string("WireGuard configuration")
        case "socks5": return AppLocalization.string("SOCKS5")
        default: return format.uppercased()
        }
    }
}
