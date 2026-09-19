import Foundation
import Testing
@testable import MClashApp

@Suite("Xray access records")
struct XrayAccessRecordTests {
    @Test("Xray selected, routed and default paths all retain entrance and outbound")
    func parsesDetourKinds() {
        for separator in [" ==> ", " -> ", " >> "] {
            let record = XrayAccessLogParser().parse("2026/09/17 14:00:00.123456 from 127.0.0.1:4321 accepted tcp:example.com:443 [HTTP\(separator)direct]")
            #expect(record?.inbound == "HTTP")
            #expect(record?.outbound == "direct")
        }
    }

    @Test("Access lines retain destination, inbound and outbound")
    func parsesRoute() {
        let line = "2026/09/16 00:08:25.905512 from 127.0.0.1:50865 accepted //chatgpt.com:443 [HTTP 2 -> n-9299]"
        let record = XrayAccessLogParser().parse(line, now: Date(timeIntervalSince1970: 1))
        #expect(record?.transport == "http")
        #expect(record?.destination == "chatgpt.com:443")
        #expect(record?.inbound == "HTTP 2")
        #expect(record?.outbound == "n-9299")
    }

    @Test("Malformed and rejected lines do not become traffic records")
    func rejectsMalformed() {
        let parser = XrayAccessLogParser()
        #expect(parser.parse("not an access line") == nil)
        #expect(parser.parse("2026/09/16 00:08:25.905512 from x rejected tcp:bad:443") == nil)
    }

    @Test("IPv6 target brackets are kept separate from the route suffix")
    func preservesIPv6Target() {
        let line = "2026/09/16 00:08:25.905512 from 127.0.0.1:50865 accepted tcp:[2001:db8::1]:443 [HTTP CONNECT -> secure node]"
        let record = XrayAccessLogParser().parse(line)
        #expect(record?.transport == "tcp")
        #expect(record?.destination == "[2001:db8::1]:443")
        #expect(record?.inbound == "HTTP CONNECT")
        #expect(record?.outbound == "secure node")
    }

    @Test("HTTP forward, CONNECT, TCP, and UDP accepted entries are recognized")
    func parsesAcceptedKinds() {
        let parser = XrayAccessLogParser()
        let cases = [
            (target: "//example.com:443", transport: "http", destination: "example.com:443"),
            (target: "tcp:example.com:443", transport: "tcp", destination: "example.com:443"),
            (target: "udp:1.1.1.1:53", transport: "udp", destination: "1.1.1.1:53"),
            (target: "http://example.com:80", transport: "http", destination: "example.com:80")
        ]
        for item in cases {
            let line = "2026/09/16 00:08:25.905512 from 127.0.0.1:1 accepted \(item.target) [in -> out]"
            let record = parser.parse(line)
            #expect(record?.transport == item.transport)
            #expect(record?.destination == item.destination)
            #expect(record?.inbound == "in")
            #expect(record?.outbound == "out")
        }
    }

    @Test("MClash probe and DNS inbounds are excluded from user traffic")
    func excludesInternalRecords() {
        let parser = XrayAccessLogParser()
        let prefix = "2026/09/16 00:08:25.905512 from 127.0.0.1:1 accepted tcp:example.com:443"
        #expect(parser.parse(prefix + " [probe-node-id -> node] reason email: probe@example.com") == nil)
        #expect(parser.parse(prefix + " [dns-query -> dns-direct]") == nil)
        #expect(parser.parse(prefix + " [probe -> node]")?.inbound == "probe")
        #expect(parser.parse(prefix + " [malformed route]") == nil)
        #expect(parser.parse(prefix + " [ -> node]") == nil)
        #expect(parser.parse(prefix + " [in -> ]") == nil)
    }

    @Test("Xray reason and email suffixes do not pollute target or route")
    func ignoresTrailingMetadata() {
        let line = "2026/09/16 00:08:25.905512 from 127.0.0.1:1 accepted tcp:[2001:db8::1]:443 [socks-in -> node] accepted email: user@example.com"
        let record = XrayAccessLogParser().parse(line)
        #expect(record?.destination == "[2001:db8::1]:443")
        #expect(record?.inbound == "socks-in")
        #expect(record?.outbound == "node")
    }
}
