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
    }
}
