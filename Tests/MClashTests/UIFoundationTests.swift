import Foundation
import Testing
@testable import MClashApp

@Suite("Shared UI formatting")
struct UIFoundationTests {
    @Test("Zero and negative byte values remain numeric")
    func zeroBytesNeverSpellOutZero() {
        #expect(formattedByteCount(0) == "0 B")
        #expect(formattedByteCount(-1) == "0 B")
        #expect(formattedByteRate(0) == "0 B/s")
        #expect(formattedByteCount(0, style: .memory) == "0 B")
        #expect(!formattedByteRate(0).localizedCaseInsensitiveContains("zero"))
    }

    @Test("Nonzero units, rates, totals, and grouped counts remain compact")
    func safeTotalsAndCounts() {
        let oneKiB = formattedByteCount(1_024)
        let oneMiBOfMemory = formattedByteCount(1_048_576, style: .memory)
        let maximum = formattedByteCount(Int64.max)
        #expect(oneKiB != "0 B")
        #expect(oneKiB.localizedCaseInsensitiveContains("B"))
        #expect(oneMiBOfMemory != "0 B")
        #expect(oneMiBOfMemory.localizedCaseInsensitiveContains("MB"))
        #expect(formattedByteRate(1_024) == "\(oneKiB)/s")
        #expect(!maximum.localizedCaseInsensitiveContains("TB"))
        #expect(maximum.localizedCaseInsensitiveContains("PB")
            || maximum.localizedCaseInsensitiveContains("EB"))
        #expect(saturatingByteSum(-10, 20) == 20)
        #expect(saturatingByteSum(Int64.max, 1) == Int64.max)
        #expect(formattedCount(0) == "0")
        #expect(formattedCount(12_345) != "12345")
    }

    @Test("Runtime timestamps reject provider zero values")
    func runtimeTimestampValidation() {
        #expect(parsedRuntimeTimestamp("0001-01-01T00:00:00Z") == nil)
        #expect(parsedRuntimeTimestamp("not-a-date") == nil)

        let timestamp = parsedRuntimeTimestamp("2026-07-16T08:00:00+08:00")
        #expect(timestamp != nil)
    }
}
