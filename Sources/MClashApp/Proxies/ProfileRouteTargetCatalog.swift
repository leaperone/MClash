import Foundation

struct ProfileRouteTargetCatalog: Equatable, Sendable {
    let profileID: ProfileID
    let subRules: [String]
    let policyGroups: [String]
    let proxyNodes: [String]
    let isLive: Bool

    static func empty(profileID: ProfileID) -> ProfileRouteTargetCatalog {
        ProfileRouteTargetCatalog(
            profileID: profileID,
            subRules: [],
            policyGroups: [],
            proxyNodes: [],
            isLive: false
        )
    }
}

struct ProfileRouteTargetCatalogReader: Sendable {
    func read(profileID: ProfileID, data: Data) -> ProfileRouteTargetCatalog {
        let structure = ProfileStructureReader().read(data: data)
        let groups = structure.groupOrder
        let groupSet = Set(groups)
        let nodes = groups
            .flatMap { structure.membersByGroup[$0] ?? [] }
            .filter { !groupSet.contains($0) && !Self.builtInTargets.contains($0) }
        return ProfileRouteTargetCatalog(
            profileID: profileID,
            subRules: subRuleNames(in: data),
            policyGroups: Self.stableUnique(groups),
            proxyNodes: Self.stableUnique(nodes),
            isLive: false
        )
    }

    private func subRuleNames(in data: Data) -> [String] {
        guard let yaml = String(data: data, encoding: .utf8) else { return [] }
        var sectionIndent: Int?
        var childIndent: Int?
        var names: [String] = []

        for rawLine in yaml.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = stripComment(String(rawLine))
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let indent = indentation(of: line)

            if sectionIndent == nil {
                if trimmed == "sub-rules:" { sectionIndent = indent }
                continue
            }
            guard let sectionIndent else { continue }
            if indent <= sectionIndent { break }
            if trimmed.hasPrefix("-") { continue }
            if childIndent == nil { childIndent = indent }
            guard indent == childIndent,
                  let colon = topLevelColon(in: trimmed) else { continue }
            let rawName = String(trimmed[..<colon])
            if let name = decodeScalar(rawName), !name.isEmpty {
                names.append(name)
            }
        }
        return Self.stableUnique(names)
    }

    private static let builtInTargets: Set<String> = [
        "DIRECT", "REJECT", "REJECT-DROP", "PASS", "COMPATIBLE", "GLOBAL",
    ]

    private static func stableUnique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }
}

private func indentation(of line: String) -> Int {
    line.prefix { $0 == " " || $0 == "\t" }.reduce(into: 0) { result, character in
        result += character == "\t" ? 2 : 1
    }
}

private func stripComment(_ line: String) -> String {
    var quote: Character?
    var escaped = false
    for index in line.indices {
        let character = line[index]
        if escaped {
            escaped = false
        } else if character == "\\", quote == "\"" {
            escaped = true
        } else if character == "\"" || character == "'" {
            quote = quote == character ? nil : (quote == nil ? character : quote)
        } else if character == "#", quote == nil {
            return String(line[..<index])
        }
    }
    return line
}

private func topLevelColon(in value: String) -> String.Index? {
    var quote: Character?
    var escaped = false
    for index in value.indices {
        let character = value[index]
        if escaped {
            escaped = false
        } else if character == "\\", quote == "\"" {
            escaped = true
        } else if character == "\"" || character == "'" {
            quote = quote == character ? nil : (quote == nil ? character : quote)
        } else if character == ":", quote == nil {
            return index
        }
    }
    return nil
}

private func decodeScalar(_ rawValue: String) -> String? {
    let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !value.isEmpty else { return nil }
    if value.hasPrefix("\"") && value.hasSuffix("\""),
       let data = value.data(using: .utf8),
       let decoded = try? JSONDecoder().decode(String.self, from: data) {
        return decoded
    }
    if value.hasPrefix("'") && value.hasSuffix("'") {
        return String(value.dropFirst().dropLast())
            .replacingOccurrences(of: "''", with: "'")
    }
    return value
}
