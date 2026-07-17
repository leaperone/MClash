import Foundation
import Testing
@testable import MClashApp

@Suite("Subscription URL routing")
struct SubscriptionURLRouterTests {
    @Test("Clash compatible and MClash links decode subscription requests")
    func parsesSupportedLinks() throws {
        let clash = try #require(
            URL(string: "clash://install-config?url=https%3A%2F%2Fexample.com%2Fsub.yaml&name=Work")
        )
        let mclash = try #require(
            URL(string: "mclash://subscribe?url=https%3A%2F%2Fexample.com%2Fsub.yaml")
        )

        #expect(
            try SubscriptionURLRouter.parse(clash)
                == SubscriptionImportRequest(
                    name: "Work",
                    url: URL(string: "https://example.com/sub.yaml")!
                )
        )
        #expect(try SubscriptionURLRouter.parse(mclash).name == "example.com")
    }

    @Test("Unsafe and unrelated links are rejected")
    func rejectsUnsupportedLinks() throws {
        let unsafe = try #require(URL(string: "mclash://subscribe?url=file%3A%2F%2F%2Ftmp%2Fx"))
        let insecure = try #require(
            URL(string: "mclash://subscribe?url=http%3A%2F%2F127.0.0.1%2Fprofile.yaml")
        )
        let unrelated = try #require(URL(string: "https://example.com/sub.yaml"))
        #expect(throws: SubscriptionURLRouterError.self) {
            try SubscriptionURLRouter.parse(unsafe)
        }
        #expect(throws: SubscriptionURLRouterError.self) {
            try SubscriptionURLRouter.parse(insecure)
        }
        #expect(throws: SubscriptionURLRouterError.self) {
            try SubscriptionURLRouter.parse(unrelated)
        }
    }

    @Test("Confirmation display host excludes credentials and path")
    func displayHostIsSanitized() throws {
        let link = try #require(
            URL(
                string: "mclash://subscribe?url=https%3A%2F%2Fuser%3Asecret%40example.com%2Fprivate%3Ftoken%3Dhidden"
            )
        )

        let request = try SubscriptionURLRouter.parse(link)

        #expect(request.displayHost == "example.com")
        #expect(!request.displayHost.contains("secret"))
        #expect(!request.displayHost.contains("token"))
    }
}
