import Foundation
import Testing
@testable import MClashNetworkShared

@Suite("MClash HTTP CONNECT codec")
struct HTTPProxyCodecTests {
    @Test("CONNECT requests preserve host, port, and normalized headers")
    func decodesConnect() throws {
        let request = try HTTPProxyCodec.decodeConnectRequest(Data(
            "CONNECT [2001:db8::1]:443 HTTP/1.1\r\nHost: example\r\nProxy-Connection: keep-alive\r\n\r\n".utf8
        ))
        #expect(request.host == "2001:db8::1")
        #expect(request.port == 443)
        #expect(request.headers["host"] == "example")
        #expect(request.headers["proxy-connection"] == "keep-alive")
    }

    @Test("Codec rejects non-CONNECT methods and malformed targets")
    func rejectsInvalidRequests() throws {
        #expect(throws: HTTPProxyCodecError.unsupportedMethod) {
            try HTTPProxyCodec.decodeConnectRequest(Data(
                "GET http://example.com/ HTTP/1.1\r\n\r\n".utf8
            ))
        }
        #expect(throws: HTTPProxyCodecError.invalidTarget) {
            try HTTPProxyCodec.decodeConnectRequest(Data(
                "CONNECT example.com HTTP/1.1\r\n\r\n".utf8
            ))
        }
    }

    @Test("Responses are bounded and suitable for direct MClash listeners")
    func encodesResponses() {
        #expect(String(decoding: HTTPProxyCodec.encodeEstablishedResponse(), as: UTF8.self)
            == "HTTP/1.1 200 Connection Established\r\n\r\n")
        #expect(String(decoding: HTTPProxyCodec.encodeFailureResponse(), as: UTF8.self)
            .hasPrefix("HTTP/1.1 502 Bad Gateway"))
    }

    @Test("Encodes authenticated HTTP CONNECT request")
    func outboundConnectRequest() throws {
        let data = try HTTPProxyCodec.encodeConnectRequest(
            host: "example.com", port: 443, username: "alice", password: "secret",
            extraHeaders: ["X-MClash": "native"]
        )
        #expect(String(decoding: data, as: UTF8.self) ==
            "CONNECT example.com:443 HTTP/1.1\r\n" +
            "Host: example.com:443\r\n" +
            "Proxy-Authorization: Basic YWxpY2U6c2VjcmV0\r\n" +
            "X-MClash: native\r\n\r\n")
    }

    @Test("Accepts only complete successful CONNECT responses")
    func outboundConnectResponse() throws {
        #expect(try HTTPProxyCodec.decodeConnectResponse(
            Data("HTTP/1.1 200 Connection Established\r\n\r\n".utf8)
        ) == 200)
        #expect(throws: HTTPProxyCodecError.truncatedHeaders) {
            try HTTPProxyCodec.decodeConnectResponse(Data("HTTP/1.1 200 OK\r\n".utf8))
        }
        #expect(throws: HTTPProxyCodecError.proxyRejected(status: 407)) {
            try HTTPProxyCodec.decodeConnectResponse(Data("HTTP/1.1 407 Proxy Authentication Required\r\n\r\n".utf8))
        }
    }

    @Test("Rejects credential mismatch and header injection")
    func outboundConnectValidation() {
        #expect(throws: HTTPProxyCodecError.invalidHeader) {
            try HTTPProxyCodec.encodeConnectRequest(host: "example.com", port: 443, username: "alice")
        }
        #expect(throws: HTTPProxyCodecError.invalidHeader) {
            try HTTPProxyCodec.encodeConnectRequest(
                host: "example.com", port: 443,
                extraHeaders: ["X-Test": "ok\r\nInjected: yes"]
            )
        }
    }
}
