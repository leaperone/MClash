import Foundation
@testable import MClashApp
import MClashNetworkShared
import Testing

@Suite("Proxifier rule importer")
struct ProxifierRuleImporterTests {
    @Test("Rules, masks, actions, disabled state, and safe defaults convert")
    func convertsProfile() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <ProxifierProfile version="101" platform="MacOSX">
          <ProxyList>
            <Proxy id="100">
              <Address>proxy.invalid</Address>
              <Options><Username>sentinel-user</Username><Password>sentinel-secret</Password></Options>
            </Proxy>
          </ProxyList>
          <RuleList>
            <Rule enabled="true">
              <Name>OpenAI Apps</Name>
              <Applications>"ChatGPT Atlas"; com.openai.atlas; *codex*</Applications>
              <Targets>*.openai.com; *oaistatic.com; 192.168.*; 203.0.113.8; 198.51.100.0/24; *.openai.com; %ComputerName%</Targets>
              <Ports>80; 443; 8000-9000; 80</Ports>
              <Action type="Proxy">100</Action>
            </Rule>
            <Rule enabled="false">
              <Name>Block Ads</Name>
              <Targets>ads.*</Targets>
              <Action type="Block"/>
            </Rule>
            <Rule enabled="true">
              <Name>Default</Name>
              <Action type="Direct"/>
            </Rule>
          </RuleList>
        </ProxifierProfile>
        """

        let plan = try ProxifierRuleImporter().makePlan(
            data: Data(xml.utf8),
            sourceName: "Rules.ppx",
            existingRules: []
        )

        #expect(plan.items.count == 3)
        #expect(plan.importableCount == 2)
        #expect(plan.skippedCount == 1)
        let proxyRule = try #require(plan.items[0].rule)
        #expect(proxyRule.protocols == [.tcp])
        #expect(proxyRule.action == .mihomo(.profileRules))
        #expect(proxyRule.unavailableFallback == .reject)
        #expect(proxyRule.sources.count == 3)
        #expect(proxyRule.destinations == [
            .hostPattern(try HostPatternMatcher(pattern: "*.openai.com")),
            .hostPattern(try HostPatternMatcher(pattern: "*oaistatic.com")),
            .network(try IPNetwork("192.168.0.0/16")),
            .ip(try IPAddress("203.0.113.8")),
            .network(try IPNetwork("198.51.100.0/24")),
        ])
        #expect(proxyRule.portRanges == [
            try PortRange(80),
            try PortRange(443),
            try PortRange(lowerBound: 8_000, upperBound: 9_000),
        ])
        #expect(plan.items[0].notes.contains(where: { $0.contains("Dynamic target") }))
        #expect(plan.items[0].selectedByDefault == false)

        let blockRule = try #require(plan.items[1].rule)
        #expect(!blockRule.enabled)
        #expect(blockRule.action == .reject)
        #expect(plan.items[2].rule == nil)

        let preview = String(describing: plan)
        #expect(!preview.contains("sentinel-user"))
        #expect(!preview.contains("sentinel-secret"))
        #expect(!preview.contains("proxy.invalid"))
    }

    @Test("Duplicate names are resolved and risky catch-all rules require selection")
    func resolvesNamesAndCatchAll() throws {
        let existing = try CaptureRule(id: "Global", priority: 10, action: .direct)
        let xml = """
        <ProxifierProfile version="101" platform="MacOSX">
          <RuleList>
            <Rule enabled="false">
              <Name>Global</Name>
              <Action type="Chain">200</Action>
            </Rule>
          </RuleList>
        </ProxifierProfile>
        """
        let plan = try ProxifierRuleImporter().makePlan(
            data: Data(xml.utf8),
            sourceName: "Global.ppx",
            existingRules: [existing]
        )
        let item = try #require(plan.items.first)
        #expect(item.importedName == "Global 2")
        #expect(item.rule?.priority == 20)
        #expect(item.rule?.action == .mihomo(.profileRules))
        #expect(item.rule?.unavailableFallback == .reject)
        #expect(item.isCatchAll)
        #expect(!item.selectedByDefault)
    }

    @Test("Numeric-leading hostnames stay valid while IP ranges and non-contiguous masks are lossy")
    func distinguishesHostnamesFromUnsupportedIPCriteria() throws {
        let xml = """
        <ProxifierProfile version="101" platform="MacOSX"><RuleList>
          <Rule><Name>Targets</Name>
            <Targets>1-example.com; 192.168.1.1-192.168.1.9; 192.*.1.*</Targets>
            <Action type="Proxy">1</Action>
          </Rule>
        </RuleList></ProxifierProfile>
        """

        let plan = try ProxifierRuleImporter().makePlan(
            data: Data(xml.utf8), sourceName: "Targets.ppx", existingRules: []
        )
        let item = try #require(plan.items.first)
        let rule = try #require(item.rule)
        #expect(rule.destinations == [
            .host(try HostMatcher(kind: .exact, value: "1-example.com")),
        ])
        #expect(item.notes.count(where: { $0.contains("unsupported") }) == 2)
        #expect(!item.selectedByDefault)
    }

    @Test("Names are display-safe and priority overflow is rejected without trapping")
    func sanitizesNamesAndRejectsPriorityOverflow() throws {
        let xml = """
        <ProxifierProfile version="101" platform="MacOSX"><RuleList>
          <Rule><Name>  Unsafe
          Name\tHere  </Name><Applications>example</Applications><Action type="Direct"/></Rule>
        </RuleList></ProxifierProfile>
        """
        let plan = try ProxifierRuleImporter().makePlan(
            data: Data(xml.utf8), sourceName: "Names.ppx", existingRules: []
        )
        #expect(plan.items.first?.importedName == "Unsafe Name Here")

        let existing = try CaptureRule(id: "last", priority: .max, action: .direct)
        #expect(throws: ProxifierRuleImportError.cannotAppendRules) {
            try ProxifierRuleImporter().makePlan(
                data: Data(xml.utf8), sourceName: "Overflow.ppx", existingRules: [existing]
            )
        }
    }

    @Test("Criteria have bounded length and total count")
    func enforcesCriteriaBudgets() {
        let longToken = String(repeating: "a", count: 1_025)
        let longXML = """
        <ProxifierProfile version="101" platform="MacOSX"><RuleList>
          <Rule><Applications>\(longToken)</Applications><Action type="Direct"/></Rule>
        </RuleList></ProxifierProfile>
        """
        #expect(throws: ProxifierRuleImportError.criterionTooLong) {
            try ProxifierRuleImporter().makePlan(
                data: Data(longXML.utf8), sourceName: "Long.ppx", existingRules: []
            )
        }

        let tooMany = Array(repeating: "a", count: 50_001).joined(separator: ";")
        let manyXML = """
        <ProxifierProfile version="101" platform="MacOSX"><RuleList>
          <Rule><Applications>\(tooMany)</Applications><Action type="Direct"/></Rule>
        </RuleList></ProxifierProfile>
        """
        #expect(throws: ProxifierRuleImportError.tooManyCriteria) {
            try ProxifierRuleImporter().makePlan(
                data: Data(manyXML.utf8), sourceName: "Many.ppx", existingRules: []
            )
        }
    }

    @Test("DTD and entity declarations are rejected before XML parsing")
    func rejectsUnsafeXML() {
        let xml = """
        <!DOCTYPE profile [<!ENTITY secret SYSTEM "file:///etc/passwd">]>
        <ProxifierProfile version="101" platform="MacOSX">
          <RuleList><Rule><Name>&secret;</Name><Action type="Direct"/></Rule></RuleList>
        </ProxifierProfile>
        """
        #expect(throws: ProxifierRuleImportError.unsafeXML) {
            try ProxifierRuleImporter().makePlan(
                data: Data(xml.utf8),
                sourceName: "Unsafe.ppx",
                existingRules: []
            )
        }
    }

    @Test("Quoted application names preserve spaces and malformed quotes fail")
    func parsesQuotedApplications() throws {
        let valid = """
        <ProxifierProfile version="101" platform="MacOSX"><RuleList>
          <Rule><Name>Apps</Name><Applications>"Example App"; helper?</Applications><Action type="Proxy">1</Action></Rule>
        </RuleList></ProxifierProfile>
        """
        let plan = try ProxifierRuleImporter().makePlan(
            data: Data(valid.utf8), sourceName: "Apps.ppx", existingRules: []
        )
        #expect(plan.items.first?.rule?.sources.count == 2)

        let invalid = valid.replacingOccurrences(of: "\"Example App\"", with: "\"Example App")
        #expect(throws: ProxifierRuleImportError.malformedList) {
            try ProxifierRuleImporter().makePlan(
                data: Data(invalid.utf8), sourceName: "Bad.ppx", existingRules: []
            )
        }
    }

    @Test("Opt-in local PPX integration fixture parses")
    func parsesOptInLocalProfile() throws {
        guard let path = ProcessInfo.processInfo.environment["MCLASH_TEST_PROXIFIER_PROFILE"] else {
            return
        }
        let url = URL(fileURLWithPath: path)
        let plan = try ProxifierRuleImporter().makePlan(
            data: Data(contentsOf: url),
            sourceName: url.lastPathComponent,
            existingRules: []
        )
        #expect(plan.items.count == 30)
        #expect(plan.importableCount == 29)
        #expect(plan.items.filter(\.selectedByDefault).count == 27)
        #expect(plan.items.first?.originalName == "codex [auto-created]")
        #expect(plan.items.first?.rule?.enabled == false)
        #expect(plan.items.first?.rule?.action == .direct)
        #expect(plan.items.first?.rule?.priority == 10)

        let localhost = try #require(plan.items.first(where: { $0.originalName == "Localhost" }))
        #expect(localhost.rule?.destinations.count == 4)
        #expect(localhost.notes.contains(where: { $0.contains("Dynamic target") }))
        #expect(!localhost.selectedByDefault)

        let global = try #require(plan.items.first(where: { $0.originalName == "Global" }))
        #expect(global.rule?.enabled == false)
        #expect(global.rule?.action == .mihomo(.profileRules))
        #expect(global.rule?.unavailableFallback == .reject)
        #expect(global.isCatchAll)
        #expect(!global.selectedByDefault)

        let gfw = try #require(plan.items.first(where: { $0.originalName == "GFWList Domains" }))
        #expect(gfw.rule?.enabled == true)
        #expect(gfw.rule?.action == .mihomo(.profileRules))
        #expect(gfw.rule?.unavailableFallback == .reject)
        #expect(gfw.rule?.destinations.count == 2_954)
        #expect(gfw.selectedByDefault)

        let defaultRule = try #require(plan.items.last)
        #expect(defaultRule.originalName == "Default")
        #expect(defaultRule.rule == nil)
        #expect(!defaultRule.selectedByDefault)
        #expect(plan.items.compactMap(\.rule).flatMap(\.destinations).count == 2_993)
        #expect(plan.items.compactMap(\.rule).map(\.priority) == Array(stride(from: 10, through: 290, by: 10)))
    }
}
