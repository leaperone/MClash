import Foundation

struct ProfileStructure: Equatable, Sendable {
    let groupOrder: [String]
    let membersByGroup: [String: [String]]

    static let empty = ProfileStructure(groupOrder: [], membersByGroup: [:])
}

/// Extracts only proxy-group names and member ordering. It deliberately retains no raw YAML,
/// subscription URLs, provider payloads, or parser diagnostics containing profile contents.
struct ProfileStructureReader: Sendable {
    func read(data: Data) -> ProfileStructure {
        guard let yaml = String(data: data, encoding: .utf8) else { return .empty }
        return read(yaml: yaml)
    }

    func read(yaml: String) -> ProfileStructure {
        var sectionIndent: Int?
        var currentGroup: String?
        var currentGroupIndent = 0
        var proxiesIndent: Int?
        var groupOrder: [String] = []
        var membersByGroup: [String: [String]] = [:]

        func registerGroup(_ rawName: String) {
            guard let name = parseYAMLScalar(rawName), !name.isEmpty else { return }
            currentGroup = name
            proxiesIndent = nil
            if !groupOrder.contains(name) {
                groupOrder.append(name)
            }
            if membersByGroup[name] == nil {
                membersByGroup[name] = []
            }
        }

        func registerMembers(_ rawMembers: [String]) {
            guard let currentGroup else { return }
            for rawMember in rawMembers {
                guard let member = parseYAMLScalar(rawMember), !member.isEmpty else { continue }
                membersByGroup[currentGroup, default: []].append(member)
            }
        }

        for rawLine in yaml.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = stripYAMLComment(String(rawLine))
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let indent = yamlIndent(of: line)

            if sectionIndent == nil {
                if trimmed == "proxy-groups:" {
                    sectionIndent = indent
                }
                continue
            }

            guard let baseIndent = sectionIndent else { continue }
            if indent <= baseIndent,
               !trimmed.hasPrefix("-"),
               trimmed != "proxy-groups:" {
                break
            }

            if trimmed.hasPrefix("- {") || trimmed.hasPrefix("-{") {
                let mapText = String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)
                let fields = parseInlineYAMLMap(mapText)
                if let name = fields["name"] {
                    registerGroup(name)
                    currentGroupIndent = indent
                    if let proxies = fields["proxies"] {
                        registerMembers(parseInlineYAMLList(proxies))
                    }
                }
                continue
            }

            if let name = yamlValue(after: "- name:", in: trimmed) {
                registerGroup(name)
                currentGroupIndent = indent
                continue
            }

            if trimmed == "-" {
                currentGroup = nil
                proxiesIndent = nil
                currentGroupIndent = indent
                continue
            }

            if currentGroup == nil,
               indent > currentGroupIndent,
               let name = yamlValue(after: "name:", in: trimmed) {
                registerGroup(name)
                continue
            }

            if let proxies = yamlValue(after: "proxies:", in: trimmed), currentGroup != nil {
                proxiesIndent = indent
                if !proxies.isEmpty {
                    registerMembers(parseInlineYAMLList(proxies))
                }
                continue
            }

            if let proxiesIndent,
               indent >= proxiesIndent,
               trimmed.hasPrefix("-") {
                let member = String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)
                registerMembers([member])
                continue
            }

            if let currentProxiesIndent = proxiesIndent, indent <= currentProxiesIndent {
                proxiesIndent = nil
            }
        }

        return ProfileStructure(groupOrder: groupOrder, membersByGroup: membersByGroup)
    }
}

private func yamlIndent(of line: String) -> Int {
    line.prefix { $0 == " " || $0 == "\t" }.reduce(into: 0) { result, character in
        result += character == "\t" ? 2 : 1
    }
}

private func yamlValue(after prefix: String, in value: String) -> String? {
    guard value.hasPrefix(prefix) else { return nil }
    return String(value.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
}

private func stripYAMLComment(_ line: String) -> String {
    var quote: Character?
    var escaped = false
    for index in line.indices {
        let character = line[index]
        if escaped {
            escaped = false
            continue
        }
        if character == "\\", quote == "\"" {
            escaped = true
            continue
        }
        if character == "\"" || character == "'" {
            if quote == character {
                quote = nil
            } else if quote == nil {
                quote = character
            }
            continue
        }
        if character == "#", quote == nil {
            return String(line[..<index])
        }
    }
    return line
}

private func parseYAMLScalar(_ rawValue: String) -> String? {
    let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !value.isEmpty, value != "null", value != "~" else { return nil }

    if value.hasPrefix("\"") && value.hasSuffix("\"") {
        if let data = value.data(using: .utf8),
           let decoded = try? JSONDecoder().decode(String.self, from: data) {
            return decoded
        }
        return String(value.dropFirst().dropLast())
    }
    if value.hasPrefix("'") && value.hasSuffix("'") {
        return String(value.dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'")
    }
    return value
}

private func parseInlineYAMLMap(_ rawValue: String) -> [String: String] {
    let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
    guard value.hasPrefix("{"), value.hasSuffix("}") else { return [:] }
    let body = String(value.dropFirst().dropLast())
    return splitYAMLTopLevel(body, separator: ",").reduce(into: [:]) { result, field in
        guard let colon = firstYAMLTopLevelIndex(of: ":", in: field) else { return }
        let key = String(field[..<colon]).trimmingCharacters(in: .whitespaces)
        let valueStart = field.index(after: colon)
        let fieldValue = String(field[valueStart...]).trimmingCharacters(in: .whitespaces)
        if let parsedKey = parseYAMLScalar(key), !parsedKey.isEmpty {
            result[parsedKey] = fieldValue
        }
    }
}

private func parseInlineYAMLList(_ rawValue: String) -> [String] {
    let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
    guard value.hasPrefix("["), value.hasSuffix("]") else {
        return value.isEmpty ? [] : [value]
    }
    return splitYAMLTopLevel(String(value.dropFirst().dropLast()), separator: ",")
}

private func splitYAMLTopLevel(_ value: String, separator: Character) -> [String] {
    var result: [String] = []
    var start = value.startIndex
    var quote: Character?
    var escaped = false
    var depth = 0

    for index in value.indices {
        let character = value[index]
        if escaped {
            escaped = false
            continue
        }
        if character == "\\", quote == "\"" {
            escaped = true
            continue
        }
        if character == "\"" || character == "'" {
            if quote == character {
                quote = nil
            } else if quote == nil {
                quote = character
            }
            continue
        }
        guard quote == nil else { continue }
        if character == "[" || character == "{" { depth += 1 }
        if character == "]" || character == "}" { depth -= 1 }
        if character == separator, depth == 0 {
            result.append(String(value[start..<index]).trimmingCharacters(in: .whitespaces))
            start = value.index(after: index)
        }
    }
    result.append(String(value[start...]).trimmingCharacters(in: .whitespaces))
    return result.filter { !$0.isEmpty }
}

private func firstYAMLTopLevelIndex(of target: Character, in value: String) -> String.Index? {
    var quote: Character?
    var escaped = false
    var depth = 0
    for index in value.indices {
        let character = value[index]
        if escaped {
            escaped = false
            continue
        }
        if character == "\\", quote == "\"" {
            escaped = true
            continue
        }
        if character == "\"" || character == "'" {
            if quote == character {
                quote = nil
            } else if quote == nil {
                quote = character
            }
            continue
        }
        guard quote == nil else { continue }
        if character == "[" || character == "{" { depth += 1 }
        if character == "]" || character == "}" { depth -= 1 }
        if character == target, depth == 0 { return index }
    }
    return nil
}
