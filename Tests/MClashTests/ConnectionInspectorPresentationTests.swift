import Testing
@testable import MClashApp

@Suite("Connection inspector presentation")
struct ConnectionInspectorPresentationTests {
    @Test("The inspector attaches only when the full workspace is wide")
    func attachesAtWideBreakpoint() {
        #expect(
            ConnectionInspectorPresentation.popover.presentation(forFullWidth: 1_099)
                == .popover
        )
        #expect(
            ConnectionInspectorPresentation.popover.presentation(forFullWidth: 1_100)
                == .attached
        )
    }

    @Test("Hysteresis prevents presentation thrash around the attach breakpoint")
    func preservesAttachedPresentationThroughHysteresisBand() {
        #expect(
            ConnectionInspectorPresentation.attached.presentation(forFullWidth: 1_050)
                == .attached
        )
        #expect(
            ConnectionInspectorPresentation.attached.presentation(forFullWidth: 979)
                == .popover
        )
    }
}
