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
}
