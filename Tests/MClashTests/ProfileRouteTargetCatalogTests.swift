import Foundation
import Testing
@testable import MClashApp

@Suite("Profile route target catalog")
struct ProfileRouteTargetCatalogTests {
    @Test("Reader discovers sub-rules, policy groups, and inline node members")
    func readsStaticTargets() {
        let profileID = ProfileID()
        let data = Data(
            """
            proxies:
              - name: Tokyo 01
                type: socks5
                server: example.com
                port: 443
            proxy-groups:
              - name: Main Route
                type: select
                proxies: [Tokyo 01, DIRECT]
              - {name: Fallback, type: fallback, proxies: [Main Route, Tokyo 02]}
            sub-rules:
              developer-tools:
                - DOMAIN-SUFFIX,example.dev,Main Route
              "media: route":
                - DOMAIN-SUFFIX,example.tv,Fallback
            rules:
              - MATCH,Main Route
            """.utf8
        )

        let catalog = ProfileRouteTargetCatalogReader().read(
            profileID: profileID,
            data: data
        )

        #expect(catalog.profileID == profileID)
        #expect(catalog.subRules == ["developer-tools", "media: route"])
        #expect(catalog.policyGroups == ["Main Route", "Fallback"])
        #expect(catalog.proxyNodes == ["Tokyo 01", "Tokyo 02"])
        #expect(!catalog.isLive)
    }
}
