import Foundation

public enum NativeFakeIPResponseRewriteError: Error, Equatable, Sendable {
    case malformedQuery
    case transactionMismatch
    case questionMismatch
    case malformedResponse
    case unsupportedQuestion
}

/// Rewrites only validated IPv4 A answers. AAAA responses are validated and
/// passed through unchanged; callers must not allocate an IPv4 fake address
/// for an IPv6 question.
public enum NativeFakeIPResponseRewriter {
    public static func rewrite(query: Data, response: Data, virtualAddress: IPAddress) throws -> Data {
        let q = try question(query)
        guard query.count >= 2, response.count >= 2, query[0] == response[0], query[1] == response[1] else { throw NativeFakeIPResponseRewriteError.transactionMismatch }
        guard q.klass == 1 else {
            throw NativeFakeIPResponseRewriteError.unsupportedQuestion
        }
        guard let responseQ = responseQuestion(response),
              responseQ.klass == q.klass,
              responseQ.type == q.type,
              responseQ.name == q.name else {
            throw NativeFakeIPResponseRewriteError.questionMismatch
        }
        guard q.type == 1 || q.type == 28 else {
            throw NativeFakeIPResponseRewriteError.unsupportedQuestion
        }
        let record: DNSResolutionRecord
        do { record = try DNSResolutionRecordParser.parse(response) } catch { throw NativeFakeIPResponseRewriteError.malformedResponse }
        guard q.type == 1 else { return response }
        guard virtualAddress.family == .ipv4 else { throw NativeFakeIPResponseRewriteError.unsupportedQuestion }
        var output = response
        var offset = 12
        _ = try readName(response, &offset)
        offset += 4
        var owners = Set<String>(); var owner = record.hostname
        for _ in 0..<16 {
            guard owners.insert(owner).inserted else { break }
            guard let next = record.aliases[owner] else { break }
            owner = next
        }
        let counts = [Int(response[6]) << 8 | Int(response[7]), Int(response[8]) << 8 | Int(response[9]), Int(response[10]) << 8 | Int(response[11])]
        for section in 0..<3 {
            for _ in 0..<counts[section] {
                let owner = try readName(response, &offset)
                guard offset + 10 <= response.count else { throw NativeFakeIPResponseRewriteError.malformedResponse }
                let type = u16(response, offset), klass = u16(response, offset + 2), length = Int(u16(response, offset + 8)); offset += 10
                guard offset + length <= response.count else { throw NativeFakeIPResponseRewriteError.malformedResponse }
                if section == 0, type == 1, klass == 1, length == 4, owners.contains(owner) {
                    output.replaceSubrange(offset..<(offset + 4), with: virtualAddress.bytes)
                }
                offset += length
            }
        }
        return output
    }

    private struct Question { let name: String; let type: UInt16; let klass: UInt16 }
    private static func responseQuestion(_ data: Data) -> Question? {
        guard data.count >= 12, data[2] & 0x80 != 0, u16(data, 4) == 1 else { return nil }
        var offset = 12
        guard let name = try? readName(data, &offset), offset + 4 <= data.count else { return nil }
        return Question(name: name, type: u16(data, offset), klass: u16(data, offset + 2))
    }
    private static func question(_ data: Data) throws -> Question {
        guard data.count >= 12, data.count <= DNSUpstreamLimits.maximumMessageBytes,
              data[2] & 0x80 == 0, u16(data, 4) == 1 else { throw NativeFakeIPResponseRewriteError.malformedQuery }
        var offset = 12
        let name: String
        do { name = try readName(data, &offset) } catch { throw NativeFakeIPResponseRewriteError.malformedQuery }
        guard !name.isEmpty, offset + 4 <= data.count else { throw NativeFakeIPResponseRewriteError.malformedQuery }
        return Question(name: name, type: u16(data, offset), klass: u16(data, offset + 2))
    }
    private static func u16(_ data: Data, _ at: Int) -> UInt16 { UInt16(data[at]) << 8 | UInt16(data[at + 1]) }
    private static func readName(_ data: Data, _ offset: inout Int) throws -> String {
        var position = offset, jumped = false, labels: [String] = [], seen = Set<Int>()
        for _ in 0..<128 {
            guard position < data.count else { throw NativeFakeIPResponseRewriteError.malformedResponse }
            let length = Int(data[position])
            if length == 0 { if !jumped { offset = position + 1 }; return labels.joined(separator: ".").lowercased() }
            if length & 0xc0 == 0xc0 {
                guard position + 1 < data.count else { throw NativeFakeIPResponseRewriteError.malformedResponse }
                let pointer = (length & 0x3f) << 8 | Int(data[position + 1])
                guard pointer < position, seen.insert(pointer).inserted else { throw NativeFakeIPResponseRewriteError.malformedResponse }
                if !jumped { offset = position + 2; jumped = true }; position = pointer; continue
            }
            guard length <= 63, position + 1 + length <= data.count,
                  let label = String(data: data[(position + 1)..<(position + 1 + length)], encoding: .utf8), !label.isEmpty else { throw NativeFakeIPResponseRewriteError.malformedResponse }
            labels.append(label); position += length + 1
        }
        throw NativeFakeIPResponseRewriteError.malformedResponse
    }
}
