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

func formattedCount(_ value: Int) -> String {
    max(0, value).formatted(.number.grouping(.automatic))
}

func saturatingByteSum(_ lhs: Int64, _ rhs: Int64) -> Int64 {
    let left = max(0, lhs)
    let right = max(0, rhs)
    let (sum, overflow) = left.addingReportingOverflow(right)
    return overflow ? Int64.max : sum
}

func parsedRuntimeTimestamp(_ value: String) -> Date? {
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let parsed = fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value)

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
