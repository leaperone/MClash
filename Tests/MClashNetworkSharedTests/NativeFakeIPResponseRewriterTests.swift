import Foundation
import Testing
@testable import MClashNetworkShared

@Suite("Native fake IP response rewriting")
struct NativeFakeIPResponseRewriterTests {
    private func packet(type: UInt16 = 1, answerType: UInt16? = nil) -> (Data, Data) {
        var query = Data([0x12, 0x34, 0x01, 0, 0, 1, 0, 0, 0, 0, 0, 0, 3])
        query.append(contentsOf: Data("www".utf8)); query.append(contentsOf: [7]); query.append(contentsOf: Data("example".utf8)); query.append(contentsOf: [3]); query.append(contentsOf: Data("com".utf8)); query.append(contentsOf: [0, UInt8(type >> 8), UInt8(type), 0, 1])
        var response = query; response[2] = 0x81; response[3] = 0; response[7] = 1
        let answerBytes: [UInt8] = type == 28 ? [0x20, 1, 0x0d, 0xb8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1] : [203, 0, 113, 7]
        response.append(contentsOf: [0xc0, 0x0c, 0, UInt8(answerType ?? type), 0, 1, 0, 0, 0, 30, UInt8(answerBytes.count >> 8), UInt8(answerBytes.count)] + answerBytes)
        return (query, response)
    }

    private func cnamePacket() -> (Data, Data) {
        var query = Data([0x45, 0x67, 0x01, 0, 0, 1, 0, 0, 0, 0, 0, 0])
        query.append(contentsOf: encodedName("example.com"))
        query.append(contentsOf: [0, 1, 0, 1])
        var response = query
        response[2] = 0x81
        response[3] = 0
        response[7] = 3

        let alias = encodedName("alias.example.com")
        response.append(contentsOf: [
            0xc0, 0x0c, 0, 5, 0, 1, 0, 0, 0, 20,
            UInt8(alias.count >> 8), UInt8(alias.count),
        ])
        response.append(contentsOf: alias)
        response.append(contentsOf: alias)
        response.append(contentsOf: [0, 1, 0, 1, 0, 0, 0, 30, 0, 4, 203, 0, 113, 9])
        response.append(contentsOf: encodedName("unrelated.example.com"))
        response.append(contentsOf: [0, 1, 0, 1, 0, 0, 0, 40, 0, 4, 192, 0, 2, 55])
        return (query, response)
    }

    private func encodedName(_ hostname: String) -> [UInt8] {
        hostname.split(separator: ".").flatMap { label in
            [UInt8(label.utf8.count)] + Array(label.utf8)
        } + [0]
    }

    @Test("Rewrites A answer while preserving transaction and question")
    func rewritesA() throws {
        let (query, response) = packet()
        let rewritten = try NativeFakeIPResponseRewriter.rewrite(query: query, response: response, virtualAddress: try IPAddress("198.18.0.2"))
        #expect(rewritten[0] == 0x12 && rewritten[1] == 0x34)
        let record = try DNSResolutionRecordParser.parse(rewritten)
        #expect(record.addresses == [try IPAddress("198.18.0.2")])
    }

    @Test("Passes AAAA through and rejects transaction mismatch")
    func ipv6AndMismatch() throws {
        let (query, response) = packet(type: 28)
        #expect(try NativeFakeIPResponseRewriter.rewrite(query: query, response: response, virtualAddress: try IPAddress("198.18.0.2")) == response)
        var mismatched = response; mismatched[0] = 0x99
        #expect(throws: NativeFakeIPResponseRewriteError.transactionMismatch) {
            _ = try NativeFakeIPResponseRewriter.rewrite(query: query, response: mismatched, virtualAddress: try IPAddress("198.18.0.2"))
        }

        let (otherQuery, _) = packet()
        var otherResponse = response
        otherResponse[13] = 0x78
        #expect(throws: NativeFakeIPResponseRewriteError.questionMismatch) {
            _ = try NativeFakeIPResponseRewriter.rewrite(query: otherQuery, response: otherResponse, virtualAddress: try IPAddress("198.18.0.2"))
        }
    }

    @Test("Rewrites the followed CNAME target without changing unrelated answers")
    func rewritesCNAMEChainOnly() throws {
        let (query, response) = cnamePacket()
        let rewritten = try NativeFakeIPResponseRewriter.rewrite(
            query: query,
            response: response,
            virtualAddress: try IPAddress("198.18.0.2")
        )
        let record = try DNSResolutionRecordParser.parse(rewritten)
        #expect(record.aliases["example.com"] == "alias.example.com")
        #expect(record.addresses == [try IPAddress("198.18.0.2")])
        #expect(Array(rewritten.suffix(4)) == [192, 0, 2, 55])
    }

    @Test("Rejects malformed query before examining response")
    func malformedQuery() throws {
        let (_, response) = packet()
        #expect(throws: NativeFakeIPResponseRewriteError.malformedQuery) {
            _ = try NativeFakeIPResponseRewriter.rewrite(query: Data([0, 1, 0]), response: response, virtualAddress: try IPAddress("198.18.0.2"))
        }
        var responseShapedQuery = response
        responseShapedQuery[2] |= 0x80
        #expect(throws: NativeFakeIPResponseRewriteError.malformedQuery) {
            _ = try NativeFakeIPResponseRewriter.rewrite(query: responseShapedQuery, response: response, virtualAddress: try IPAddress("198.18.0.2"))
        }
        let (unsupportedQuery, unsupportedResponse) = packet(type: 15)
        #expect(throws: NativeFakeIPResponseRewriteError.unsupportedQuestion) {
            _ = try NativeFakeIPResponseRewriter.rewrite(query: unsupportedQuery, response: unsupportedResponse, virtualAddress: try IPAddress("198.18.0.2"))
        }
    }
}
