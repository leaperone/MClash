import Foundation

struct XrayRuleSetValidator: Sendable {
    let binary: URL
    let directory: URL
    let commands: CoreSupervisor

    func validate(_ ruleSet: RuleSet, rules: [String]) async throws {
        var candidate = ruleSet
        candidate.rules = rules
        candidate.defaultAction = .direct
        candidate.enabled = true
        let dns = DNSPolicy(name: "Validation")
        let workspace = Workspace(name: "Validation", ruleSetIDs: [candidate.id], dnsPolicyID: dns.id)
        let document = ConfigurationDocument(ruleSets: [candidate], dnsPolicies: [dns], workspaces: [workspace])
        let plan = try XrayConfigurationCompiler.compile(document: document, workspaceID: workspace.id,
                                                        inbounds: [], apiSocketPath: "/tmp/mclash-rules-validation.sock")
        let file = directory.appending(path: "rules-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        try plan.encoded().write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        _ = try await commands.runCommand(executableURL: binary, arguments: ["run", "-test", "-config", file.path], directory: directory)
    }
}
