import Foundation
import Testing
@testable import MClashApp

struct NodeLinkImporterTests {
    @Test func importsSupportedLinksAndKeepsSecretsOutOfDiagnostics() {
        let uuid = "00000000-0000-0000-0000-000000000001"
        let vmess = Data("{\"v\":\"2\",\"ps\":\"demo\",\"add\":\"vmess.example\",\"port\":443,\"id\":\"\(uuid)\"}".utf8).base64EncodedString()
        let text = "vless://\(uuid):secret@example.com:443#V\nvmess://\(vmess)\ntrojan://secret@t.example:443#T\nss://YWVzLTI1Ni1nY206cHc=@s.example:8388#S\nhttp://u:p@h.example:80#H\nsocks5://u:p@s.example:1080#K"
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
        let preview = NodeLinkImporter().preview(.init(text: "http://u%40ser:p%20w@[::1]:443#hello%20world"))
        #expect(preview.nodes.first?.host == "::1")
        #expect(preview.nodes.first?.parameters["username"] == "u@ser")
        #expect(preview.nodes.first?.parameters["password"] == "p w")
    }

    @Test("Accepts the common socks scheme and presents it as SOCKS5")
    func importsSocksAlias() {
        let preview = NodeLinkImporter().preview(.init(text: "socks://user:password@example.com:1080#SOCKS"))
        #expect(preview.nodes.count == 1)
        #expect(preview.nodes.first?.proto == .socks5)
        #expect(preview.nodes.first?.parameters["username"] == "user")
        #expect(preview.nodes.first?.parameters["password"] == "password")
        #expect(preview.detectedFormats == ["socks5"])
        #expect(preview.diagnostics.isEmpty)
    }

    @Test("Imports a WireGuard share link with peer and address settings")
    func importsWireGuardLink() {
        let link = "wireguard://\(String(repeating: "11", count: 32))@wg.example:51820?publickey=\(String(repeating: "22", count: 32))&address=10.0.0.2%2F32&allowedips=0.0.0.0%2F0%2C%3A%3A%2F0&keepalive=25&reserved=0%2C1%2C2&dns=1.1.1.1#WG"
        let preview = NodeLinkImporter().preview(.init(text: link))
        #expect(preview.nodes.count == 1)
        #expect(preview.nodes.first?.proto == .wireguard)
        #expect(preview.nodes.first?.parameters["secret-key"] == String(repeating: "11", count: 32))
        #expect(preview.nodes.first?.parameters["public-key"] == String(repeating: "22", count: 32))
        #expect(preview.nodes.first?.parameters["address"] == "10.0.0.2/32")
        #expect(preview.nodes.first?.parameters["keep-alive"] == "25")
        #expect(preview.nodes.first?.parameters["reserved"] == "0,1,2")
        #expect(preview.nodes.first?.parameters["remote-dns"] == "1.1.1.1")
        #expect(preview.diagnostics.isEmpty)
    }
}
