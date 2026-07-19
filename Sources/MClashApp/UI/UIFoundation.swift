import AppKit
import Foundation
import SwiftUI

enum MClashLayout {
    static let mainWindowMinimumWidth: CGFloat = 900
    static let mainWindowMinimumHeight: CGFloat = 600
    static let microSpacing: CGFloat = 2
    static let tightSpacing: CGFloat = 4
    static let compactSpacing: CGFloat = 8
    static let controlSpacing: CGFloat = 12
    static let pagePadding: CGFloat = 28
    static let compactPagePadding: CGFloat = 18
    static let sectionSpacing: CGFloat = 24
    static let panelSpacing: CGFloat = 16
    static let statusBarHorizontalPadding: CGFloat = 14
    static let statusBarVerticalPadding: CGFloat = 8
}

extension AppModel.LocalListenerKind {
    var presentationTitle: String {
        switch self {
        case .http: "HTTP"
        case .socks5: "SOCKS5"
        case .mixed: "Mixed"
        }
    }

    var presentationSystemImage: String {
        switch self {
        case .http: "globe"
        case .socks5: "point.3.connected.trianglepath.dotted"
        case .mixed: "arrow.triangle.branch"
        }
    }
}

extension AppModel.LocalListenerSource {
    var presentationTitle: String {
        switch self {
        case .profile: "Profile"
        case .override: "Custom"
        case .managedFallback: "Temporary"
        }
    }
}

func formattedByteCount(
    _ value: Int64,
    style: ByteCountFormatter.CountStyle = .file
) -> String {
    let normalized = max(0, value)
    guard normalized > 0 else { return "0 B" }

    return ByteCountFormatter.string(fromByteCount: normalized, countStyle: style)
}

func formattedByteRate(_ value: Int64) -> String {
    "\(formattedByteCount(value))/s"
}

/// A menu-bar-safe rate with short, stable units and at most four characters.
/// The surrounding icon communicates direction, so `/s` is intentionally
/// omitted to keep all three status fields compact.
func compactMenuBarByteRate(_ value: Int64) -> String {
    compactMenuBarMagnitude(Double(max(0, value)), suffixes: ["B", "K", "M", "G", "T", "P", "E"])
}

func compactMenuBarCount(_ value: Int) -> String {
    compactMenuBarMagnitude(Double(max(0, value)), suffixes: ["", "K", "M", "G", "T", "P", "E"])
}

private func compactMenuBarMagnitude(_ value: Double, suffixes: [String]) -> String {
    var scaled = value
    var suffixIndex = 0
    while scaled >= 1_000, suffixIndex < suffixes.count - 1 {
        scaled /= 1_000
        suffixIndex += 1
    }
    if scaled >= 999.5, suffixIndex < suffixes.count - 1 {
        scaled /= 1_000
        suffixIndex += 1
    }

    let number: String
    if suffixIndex > 0, scaled < 9.95 {
        number = String(format: "%.1f", scaled)
    } else {
        number = String(Int(scaled.rounded()))
    }
    return number + suffixes[suffixIndex]
}

func formattedCount(_ value: Int) -> String {
    max(0, value).formatted(.number.grouping(.automatic))
}

func saturatingByteSum(_ lhs: Int64, _ rhs: Int64) -> Int64 {
    let left = max(0, lhs)
    let right = max(0, rhs)
    let (sum, overflow) = left.addingReportingOverflow(right)
    return overflow ? Int64.max : sum
}

@discardableResult
func copyToPasteboard(_ value: String) -> Bool {
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    return pasteboard.setString(value, forType: .string)
}

func parsedRuntimeTimestamp(_ value: String) -> Date? {
    let parsed = RuntimeTimestampParser.date(from: value)

    // mihomo uses the zero-value Go timestamp for providers that have never updated.
    // Treat it as missing rather than presenting "2,025 years ago" to the user.
    guard let parsed,
          parsed >= Date(timeIntervalSince1970: 946_684_800) else {
        return nil
    }
    return parsed
}

struct DisconnectedUnavailableView: View {
    @Bindable var model: AppModel
    let title: String
    let systemImage: String
    let description: String

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: systemImage)
        } description: {
            Text(description)
        } actions: {
            if model.preparationInProgress {
                HStack(spacing: 7) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Preparing MClash…")
                }
                .foregroundStyle(.secondary)
            } else if model.systemProxyRecoveryRequired {
                Button("Restore Network Settings") {
                    Task { await model.disableSystemProxy() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!model.canPerform(.changeSystemProxy))
            } else if model.activeProfile == nil {
                Button("Choose a Profile…") {
                    model.selection = .profiles
                }
                .buttonStyle(.borderedProminent)
            } else {
                Button {
                    Task { await model.toggleConnection() }
                } label: {
                    if model.isPerforming(.connection) || model.isBusy {
                        HStack(spacing: 7) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Connecting…")
                        }
                    } else {
                        Label("Connect", systemImage: "play.fill")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!model.canPerform(.connection))
            }
        }
    }
}

/// A value that behaves like a native macOS control instead of inert text.
/// The complete visible value is the hit target, while the transient checkmark
/// confirms the clipboard write without interrupting the user's workflow.
struct CopyableValueButton: View {
    let value: String
    let accessibilityName: String
    var title: String? = nil
    var systemImage: String? = nil
    var font: Font = .body
    var usesSecondaryStyle = false
    var lineLimit = 1

    @State private var copied = false
    @State private var resetTask: Task<Void, Never>?

    var body: some View {
        Button(action: copyValue) {
            HStack(spacing: 5) {
                if let systemImage {
                    Image(systemName: systemImage)
                }
                if let title {
                    Text(title)
                }
                Text(value)
                    .monospacedDigit()
                    .lineLimit(lineLimit)
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .foregroundStyle(copied ? Color.green : Color.secondary)
                    .contentTransition(.symbolEffect(.replace))
            }
            .font(font)
            .foregroundStyle(usesSecondaryStyle ? Color.secondary : Color.primary)
            .padding(.horizontal, 5)
            .padding(.vertical, 3)
            .contentShape(Rectangle())
            .background(
                copied ? Color.green.opacity(0.12) : Color.clear,
                in: RoundedRectangle(cornerRadius: 5, style: .continuous)
            )
        }
        .buttonStyle(.plain)
        .help(copied ? "Copied" : "Copy \(accessibilityName): \(value)")
        .accessibilityLabel("Copy \(accessibilityName)")
        .accessibilityValue(copied ? "Copied" : value)
        .contextMenu {
            Button("Copy") { copyValue() }
        }
        .onDisappear {
            resetTask?.cancel()
            resetTask = nil
        }
    }

    private func copyValue() {
        guard copyToPasteboard(value) else { return }

        resetTask?.cancel()
        copied = true
        resetTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.2))
            guard !Task.isCancelled else { return }
            copied = false
            resetTask = nil
        }
    }
}

extension View {
    func mclashPageSurface() -> some View {
        frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .windowBackgroundColor))
    }

    func mclashListSurface(
        horizontalMargin: CGFloat = MClashLayout.compactPagePadding,
        verticalMargin: CGFloat = 12
    ) -> some View {
        scrollContentBackground(.hidden)
            .contentMargins(.horizontal, horizontalMargin, for: .scrollContent)
            .contentMargins(.vertical, verticalMargin, for: .scrollContent)
            .background(Color(nsColor: .windowBackgroundColor))
    }
}
