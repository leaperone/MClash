import Foundation
import Testing
@testable import MClashNetworkShared

@Suite("Native hostname resolver")
struct NativeHostnameResolverTests {
    @Test("Builds bounded A and AAAA questions")
    func questions() throws {
        let query = try NativeHostnameResolver.query(for: "Example.COM.", type: .a, transactionID: 0x1234)
        #expect(query == Data([0x12, 0x34, 1, 0, 0, 1, 0, 0, 0, 0, 0, 0, 7]) + Data("example".utf8) + Data([3]) + Data("com".utf8) + Data([0, 0, 1, 0, 1]))
        #expect(throws: NativeHostnameResolver.Error.invalidHostname) {
            _ = try NativeHostnameResolver.query(for: "bad label", type: .aaaa, transactionID: 1)
        }
    }

    @Test("Parses compressed A and IPv6 answers and rejects compression loops")
    func compressedAnswers() throws {
        let ipv4 = dnsResponse(id: 0x42, questionType: .a, answers: [(.a, [192, 0, 2, 7])])
        let ipv6 = dnsResponse(
            id: 0x43,
            questionType: .aaaa,
            answers: [(.aaaa, Array(repeating: 0, count: 15) + [1])]
        )
        let parsedIPv4: [IPAddress]
        let parsedIPv6: [IPAddress]
        do {
            parsedIPv4 = try NativeHostnameResolver.parseAddresses(ipv4, name: "example.com", type: .a)
        } catch {
            let packet = ipv4.map { String(format: "%02x", $0) }.joined()
            Issue.record("Compressed IPv4 parsing failed: \(error); packet=\(packet)")
            return
        }
        do {
            parsedIPv6 = try NativeHostnameResolver.parseAddresses(
                ipv6,
                name: "example.com",
                type: .aaaa
            )
        } catch {
            Issue.record("Compressed IPv6 parsing failed: \(error)")
            return
        }
        #expect(parsedIPv4.map(\.presentation) == ["192.0.2.7"])
        #expect(parsedIPv6.map(\.presentation) == ["::1"])
        var loop = ipv4
        loop[12] = 0xc0; loop[13] = 0x0c
        #expect(throws: NativeHostnameResolver.Error.allUpstreamsFailed) {
            _ = try NativeHostnameResolver.parseAddresses(loop, name: "example.com", type: .a)
        }

        #expect(throws: NativeHostnameResolver.Error.allUpstreamsFailed) {
            _ = try NativeHostnameResolver.parseAddresses(
                ipv4,
                name: "different.example",
                type: .a
            )
        }
    }

    @Test("Falls back through literal upstreams in declaration order")
    func fallback() async throws {
        let first = try DNSUpstreamEndpoint(address: IPAddress("192.0.2.1"), transport: .udp, timeoutMilliseconds: 100)
        let second = try DNSUpstreamEndpoint(address: IPAddress("192.0.2.2"), transport: .udp, timeoutMilliseconds: 100)
        let bootstrap = try DNSUpstreamBootstrap(endpoints: [first, second])
        let resolver = NativeHostnameResolver(bootstrap: bootstrap) { endpoint in
            FixtureUpstream(response: endpoint.address == second.address ? dnsResponse(id: nil, questionType: .a, answers: [(.a, [198, 51, 100, 9])]) : nil)
        }
        #expect(try await resolver.resolve("example.com").map(\.presentation) == ["198.51.100.9"])
    }

    @Test("Resolved catalogs keep the original protocol hostname")
    func resolvesConnectorCatalogWithoutChangingSNI() async throws {
        let endpoint = try DNSUpstreamEndpoint(
            address: IPAddress("192.0.2.53"),
            transport: .udp,
            timeoutMilliseconds: 100
        )
        let resolver = NativeHostnameResolver(
            bootstrap: try DNSUpstreamBootstrap(endpoints: [endpoint])
        ) { _ in
            FixtureUpstream(
                response: dnsResponse(
                    id: nil,
                    questionType: .a,
                    answers: [(.a, [198, 51, 100, 9])]
                )
            )
        }
        let target = try OutboundNodeTarget(
            protocolName: "vless",
            host: "example.com",
            port: 443,
            parameters: ["sni": "example.com", "uuid": "secret"]
        )
        let catalog = try OutboundNodeTargetCatalog(entries: [
            .init(route: .global, target: target)
        ])

        let resolved = await resolver.resolving(catalog)
        let resolvedTarget = try #require(resolved.target(for: .global))
        #expect(resolvedTarget.host == "example.com")
        #expect(resolvedTarget.connectionHost == "198.51.100.9")
        #expect(resolvedTarget.parameters["sni"] == "example.com")
        #expect(resolvedTarget.parameters["uuid"] == "secret")
    }

    private final class FixtureUpstream: DNSUpstream, @unchecked Sendable {
        let response: Data?
        init(response: Data?) { self.response = response }
        func exchange(query: Data) async throws -> Data {
            guard var response else { throw DNSUpstreamError.timeout }
            response[0] = query[0]; response[1] = query[1]
            return response
        }
    }

    private static func dnsResponse(id: UInt16?, questionType: NativeHostnameResolver.RecordType, answers: [(NativeHostnameResolver.RecordType, [UInt8])]) -> Data {
        let transactionID = id ?? 0
        var data = Data([
            UInt8(transactionID >> 8), UInt8(transactionID & 0xff),
            0x81, 0x80, 0, 1, 0, UInt8(answers.count), 0, 0, 0, 0
        ])
        data.append(contentsOf: [7]); data.append(contentsOf: Data("example".utf8)); data.append(3); data.append(contentsOf: Data("com".utf8)); data.append(contentsOf: [0, 0, UInt8(questionType.rawValue), 0, 1])
        for (type, bytes) in answers {
            data.append(contentsOf: [0xc0, 0x0c, UInt8(type.rawValue >> 8), UInt8(type.rawValue & 0xff), 0, 1, 0, 0, 0, 30, UInt8(bytes.count >> 8), UInt8(bytes.count & 0xff)]); data.append(contentsOf: bytes)
        }
        return data
    }
    private func dnsResponse(id: UInt16? = nil, questionType: NativeHostnameResolver.RecordType, answers: [(NativeHostnameResolver.RecordType, [UInt8])]) -> Data { Self.dnsResponse(id: id, questionType: questionType, answers: answers) }
}
