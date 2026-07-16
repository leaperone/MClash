import AppKit
import Foundation
import SwiftUI

enum MClashLayout {
    static let pagePadding: CGFloat = 28
    static let compactPagePadding: CGFloat = 18
    static let sectionSpacing: CGFloat = 24
    static let panelSpacing: CGFloat = 16
}

func formattedByteCount(
    _ value: Int64,
    style: ByteCountFormatter.CountStyle = .file
) -> String {
    let normalized = max(0, value)
    guard normalized > 0 else { return "0 B" }

    let formatter = ByteCountFormatter()
    formatter.countStyle = style
    formatter.isAdaptive = true
    formatter.includesCount = true
    formatter.includesUnit = true
    formatter.includesActualByteCount = false
    return formatter.string(fromByteCount: normalized)
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
