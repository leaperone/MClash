import Foundation
import Testing
@testable import MClashApp

struct NodeLinkImporterTests {
    @Test func importsSupportedLinksAndKeepsSecretsOutOfDiagnostics() {
        let vmess = Data("{\"v\":\"2\",\"ps\":\"demo\",\"add\":\"vmess.example\",\"port\":443,\"id\":\"uuid\"}".utf8).base64EncodedString()
        let text = "vless://user:secret@example.com:443#V\nvmess://\(vmess)\ntrojan://secret@t.example:443#T\nss://YWVzLTI1Ni1nY206cHc=@s.example:8388#S\nhttp://u:p@h.example:80#H\nsocks5://u:p@s.example:1080#K"
        let preview = NodeLinkImporter().preview(.init(text: text))
        #expect(preview.nodes.count == 6)
        #expect(preview.detectedFormats.count == 6)
        #expect(preview.diagnostics.isEmpty)
        #expect(preview.nodes.contains { $0.parameters["password"] == "secret" })
        #expect(!preview.diagnostics.contains { $0.message.contains("secret") })
    }

    @Test func rejectsMalformedAndDeduplicates() {
        let link = "trojan://secret@example.com:443#one"
        let preview = NodeLinkImporter().preview(.init(text: "\(link)\n\(link)\nftp://bad.example:21"))
        #expect(preview.nodes.count == 1)
        #expect(preview.ignoredLines == 1)
        #expect(preview.diagnostics.count == 2)
        #expect(preview.diagnostics.allSatisfy { !$0.message.contains("secret") })
    }

    @Test func decodesPercentAndIPv6() {
        let preview = NodeLinkImporter().preview(.init(text: "vless://u%40ser:p%20w@[::1]:443?security=tls#hello%20world"))
        #expect(preview.nodes.first?.host == "::1")
        #expect(preview.nodes.first?.parameters["username"] == "u@ser")
        #expect(preview.nodes.first?.parameters["password"] == "p w")
    }
}
