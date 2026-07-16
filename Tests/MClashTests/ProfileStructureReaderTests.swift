import Foundation
import Testing
@testable import MClashApp

@Suite("Proxy profile structure reader")
struct ProfileStructureReaderTests {
    @Test("Block and inline proxy groups preserve only names and member order")
    func readsGroupOrderWithoutRetainingSubscriptionContent() {
        let secret = "subscription-token-must-not-escape"
        let yaml = """
        mixed-port: 7890
        proxy-groups:
          - name: "Main, Route"
            type: select
            proxies:
              - Auto
              - "Hong Kong #1" # node comment
          - { name: Auto, type: url-test, proxies: [Japan, "United States"] }
        proxy-providers:
          private:
            url: https://example.com/subscribe?(secret)
        """

        let structure = ProfileStructureReader().read(yaml: yaml)

        #expect(structure.groupOrder == ["Main, Route", "Auto"])
        #expect(structure.membersByGroup["Main, Route"] == ["Auto", "Hong Kong #1"])
        #expect(structure.membersByGroup["Auto"] == ["Japan", "United States"])
        #expect(!String(describing: structure).contains(secret))
    }

    @Test("Malformed and non UTF-8 input returns a safe empty structure")
    func invalidInputIsContentFree() {
        let reader = ProfileStructureReader()
        #expect(reader.read(data: Data([0xFF, 0xFE])) == .empty)
        #expect(reader.read(yaml: "rules:\n  - MATCH,DIRECT") == .empty)
    }

    @Test("Indentless YAML sequences are accepted")
    func readsIndentlessSequences() {
        let structure = ProfileStructureReader().read(
            yaml: """
            proxy-groups:
            - name: Main
              type: select
              proxies:
              - Auto
              - DIRECT
            rules:
            - MATCH,Main
            """
        )

        #expect(structure.groupOrder == ["Main"])
        #expect(structure.membersByGroup["Main"] == ["Auto", "DIRECT"])
    }
}
