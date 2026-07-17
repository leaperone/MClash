import Testing
@testable import MClashApp

@Suite("Proxy workspace sizing")
struct ProxyWorkspaceSizingTests {
    @Test("List columns consume the complete workspace without a blank remainder")
    func listColumnsFillAvailableWidth() {
        for width in [683.0, 970.0, 1_353.0] {
            let sidebar = ProxyWorkspaceSizing.groupSidebarWidth(for: width)
            let detail = ProxyWorkspaceSizing.detailWidth(
                for: width,
                sidebarWidth: sidebar
            )

            #expect(
                sidebar + ProxyWorkspaceSizing.dividerWidth + detail == width
            )
        }
    }

    @Test("Group Sidebar remains compact while the detail column flexes")
    func sidebarWidthIsBounded() {
        #expect(ProxyWorkspaceSizing.groupSidebarWidth(for: 683) == 190)
        #expect(ProxyWorkspaceSizing.groupSidebarWidth(for: 970) == 213.4)
        #expect(ProxyWorkspaceSizing.groupSidebarWidth(for: 1_353) == 240)
    }
}
