import Foundation
import Testing
@testable import MClashApp

@Suite("Xray access records")
struct XrayAccessRecordTests {
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

    @Test("Appended chunks preserve an access line split across writes")
    func preservesPartialLine() {
        let parser = XrayAccessLogParser()
        var pending = ""
        let first = parser.parse(
            Data("2026/09/16 00:08:25.905512 from 127.0.0.1:5".utf8),
            pendingLine: &pending,
            now: Date(timeIntervalSince1970: 1)
        )
        #expect(first.isEmpty)
        #expect(pending.hasSuffix("127.0.0.1:5"))

        let second = parser.parse(
            Data("0865 accepted tcp:example.com:443 [HTTP -> node]\n".utf8),
            pendingLine: &pending,
            now: Date(timeIntervalSince1970: 1)
        )
        #expect(second.count == 1)
        #expect(second.first?.source == "127.0.0.1:50865")
        #expect(second.first?.destination == "example.com:443")
        #expect(pending.isEmpty)
    }
}
