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

    @Test("Imports native WireGuard configuration text and creates one node per peer")
    func importsWireGuardConfigurationText() {
        let config = """
        [Interface]
        PrivateKey = \(String(repeating: "11", count: 32))
        Address = 10.0.0.2/32, fd00::2/128
        DNS = 1.1.1.1
        MTU = 1420

        [Peer]
        PublicKey = \(String(repeating: "22", count: 32))
        Endpoint = wg.example:51820
        AllowedIPs = 0.0.0.0/0, ::/0
        PersistentKeepalive = 25
        """
        let preview = NodeLinkImporter().preview(.init(text: config))
        #expect(preview.nodes.count == 1)
        #expect(preview.detectedFormats == ["wireguard-config"])
        #expect(preview.nodes.first?.proto == .wireguard)
        #expect(preview.nodes.first?.parameters["address"] == "10.0.0.2/32, fd00::2/128")
        #expect(preview.nodes.first?.parameters["allowed-ips"] == "0.0.0.0/0, ::/0")
        #expect(preview.nodes.first?.parameters["remote-dns"] == "1.1.1.1")
        #expect(preview.nodes.first?.parameters["keep-alive"] == "25")
        #expect(preview.diagnostics.isEmpty)
    }

    @Test("WireGuard configuration diagnostics identify missing peer fields")
    func rejectsIncompleteWireGuardConfiguration() {
        let config = """
        [Interface]
        PrivateKey = \(String(repeating: "11", count: 32))
        [Peer]
        Endpoint = wg.example:51820
        """
        let preview = NodeLinkImporter().preview(.init(text: config))
        #expect(preview.nodes.isEmpty)
        #expect(preview.diagnostics.first?.code == "invalid_wireguard_config")
        #expect(preview.diagnostics.first?.subject == "peer-1.publickey")
    }

    @Test("Decodes a padded Base64 node list without exposing its credentials")
    func importsPaddedBase64NodeList() {
        let uuid = "00000000-0000-0000-0000-000000000010"
        let decoded = "vless://\(uuid):secret@example.com:443#V\nvmess://invalid"
        let encoded = Data(decoded.utf8).base64EncodedString()
        let preview = NodeLinkImporter().preview(.init(text: encoded))
        #expect(preview.nodes.count == 1)
        #expect(preview.detectedFormats.contains("encoded-links"))
        #expect(preview.detectedFormats.contains("vless"))
        #expect(preview.ignoredLines == 0)
        #expect(preview.diagnostics.count == 1)
        #expect(preview.diagnostics.allSatisfy { !$0.message.contains("secret") })
    }

    @Test("Decodes URL-safe unpadded Base64 with whitespace")
    func importsURLSafeBase64NodeList() {
        let decoded = "trojan://secret@example.com:443#T\n"
        let standard = Data(decoded.utf8).base64EncodedString()
        let unpadded = standard.replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .trimmingCharacters(in: CharacterSet(charactersIn: "="))
        let preview = NodeLinkImporter().preview(.init(text: "  \(unpadded.prefix(12))\n\(unpadded.dropFirst(12))  "))
        #expect(preview.nodes.count == 1)
        #expect(preview.nodes.first?.proto == .trojan)
        #expect(preview.detectedFormats.contains("encoded-links"))
        #expect(preview.diagnostics.isEmpty)
    }

    @Test("Base64 prose is not treated as a node list")
    func rejectsEncodedProse() {
        let encoded = Data("this is ordinary text".utf8).base64EncodedString()
        let preview = NodeLinkImporter().preview(.init(text: encoded))
        #expect(preview.nodes.isEmpty)
        #expect(!preview.detectedFormats.contains("encoded-links"))
    }

    @Test("WireGuard diagnostics reject malformed CIDR values before activation")
    func rejectsMalformedWireGuardCIDR() {
        let config = """
        [Interface]
        PrivateKey = \(String(repeating: "11", count: 32))
        Address = 10.0.0.2/99
        [Peer]
        PublicKey = \(String(repeating: "22", count: 32))
        Endpoint = wg.example:51820
        AllowedIPs = 0.0.0.0/0
        """
        let preview = NodeLinkImporter().preview(.init(text: config))
        #expect(preview.nodes.isEmpty)
        #expect(preview.diagnostics.first?.subject == "interface.address")
    }
}
