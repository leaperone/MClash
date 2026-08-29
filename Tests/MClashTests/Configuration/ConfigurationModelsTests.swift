import Foundation
import Testing
@testable import MClashApp

struct ConfigurationModelsTests {
    @Test func nodeFingerprintIsStableAcrossPresentationChanges() throws {
        let a = try Node(displayName: "Tokyo", protocol: .vless, host: "EXAMPLE.com.", port: 443, parameters: ["uuid": "abc", "tls": "true"])
        let b = try Node(displayName: "Renamed", protocol: .vless, host: "example.com", port: 443, parameters: ["tls": "true", "uuid": "abc"])
        #expect(a.fingerprint == b.fingerprint)
        #expect(a.host == "example.com")
    }

    @Test func validatorProducesDeterministicDependencyDiagnostics() throws {
        let dnsID = DNSPolicyID(); let missing = NodeID()
        let workspace = Workspace(name: "Test", nodeIDs: [missing], dnsPolicyID: dnsID)
        let diagnostics = ConfigurationValidator.validate(workspace: workspace, nodes: [], groups: [], rules: [], dnsPolicies: [], entrances: [])
        #expect(diagnostics.map(\.code) == ["missing_dns_policy"])
    }

    @Test func modelsRoundTripCodable() throws {
        let dns = DNSPolicy(name: "System")
        let workspace = Workspace(name: "Daily", dnsPolicyID: dns.id)
        let data = try JSONEncoder().encode(workspace)
        let decoded = try JSONDecoder().decode(Workspace.self, from: data)
        #expect(decoded == workspace)
    }
}
