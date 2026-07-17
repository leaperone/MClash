import Foundation
@testable import MClashNetworkShared
import Testing

@Suite("SOCKS5 wire codec")
struct SOCKS5CodecTests {
    @Test
    func greetingAndAuthenticationNegotiation() throws {
        let credentials = try SOCKS5UsernamePasswordCredentials(username: "mclash", password: "secret")
        let negotiator = SOCKS5ClientAuthenticationNegotiator(credentials: credentials)

        #expect(try negotiator.greeting() == Data([0x05, 0x01, 0x02]))
        #expect(throws: SOCKS5CodecError.authenticationMethodNotOffered(0x00)) {
            try negotiator.handle(SOCKS5MethodSelection(method: .noAuthenticationRequired))
        }
        #expect(
            try negotiator.handle(SOCKS5MethodSelection(method: .usernamePassword))
                == .sendUsernamePassword(
                    Data([0x01, 0x06]) + Data("mclash".utf8) + Data([0x06]) + Data("secret".utf8)
                )
        )
        #expect(throws: SOCKS5CodecError.noAcceptableAuthenticationMethods) {
            try negotiator.handle(SOCKS5MethodSelection(method: .noAcceptableMethods))
        }
        #expect(throws: SOCKS5CodecError.authenticationMethodNotOffered(0x01)) {
            try negotiator.handle(SOCKS5MethodSelection(method: .gssAPI))
        }

        let fallback = SOCKS5ClientAuthenticationNegotiator(
            credentials: credentials,
            allowsNoAuthenticationFallback: true
        )
        #expect(try fallback.greeting() == Data([0x05, 0x02, 0x02, 0x00]))
        #expect(
            try fallback.handle(SOCKS5MethodSelection(method: .noAuthenticationRequired))
                == .authenticated
        )
    }

    @Test
    func credentialsValidateEncodedByteLength() throws {
        #expect(throws: SOCKS5CodecError.invalidUsernameLength(0)) {
            try SOCKS5UsernamePasswordCredentials(username: Data(), password: Data([1]))
        }
        #expect(throws: SOCKS5CodecError.invalidPasswordLength(256)) {
            try SOCKS5UsernamePasswordCredentials(
                username: Data([1]),
                password: Data(repeating: 1, count: 256)
            )
        }

        let unicode = try SOCKS5UsernamePasswordCredentials(username: "用户", password: "密码")
        let frame = SOCKS5Codec.encodeUsernamePasswordRequest(credentials: unicode)
        #expect(frame[0] == 0x01)
        #expect(frame[1] == UInt8(Data("用户".utf8).count))
    }

    @Test
    func usernamePasswordResponseAndFailure() throws {
        let success = try SOCKS5Codec.decodeUsernamePasswordResponse(Data([0x01, 0x00]))
        try success.requireSuccess()

        let rejected = try SOCKS5Codec.decodeUsernamePasswordResponse(Data([0x01, 0x07]))
        #expect(throws: SOCKS5CodecError.usernamePasswordRejected(0x07)) {
            try rejected.requireSuccess()
        }
        #expect(throws: SOCKS5CodecError.invalidUsernamePasswordVersion(0x05)) {
            try SOCKS5Codec.decodeUsernamePasswordResponse(Data([0x05, 0x00]))
        }
    }

    @Test
    func connectRequestsEncodeIPv4IPv6AndDomain() throws {
        let ipv4 = try request(command: .connect, ip: "192.0.2.9", port: 443)
        #expect(
            try SOCKS5Codec.encodeCommandRequest(ipv4)
                == Data([0x05, 0x01, 0x00, 0x01, 192, 0, 2, 9, 0x01, 0xBB])
        )

        let ipv6 = try request(command: .connect, ip: "2001:db8::1", port: 80)
        let ipv6Frame = try SOCKS5Codec.encodeCommandRequest(ipv6)
        #expect(ipv6Frame.prefix(4) == Data([0x05, 0x01, 0x00, 0x04]))
        #expect(ipv6Frame.count == 22)
        #expect(ipv6Frame.suffix(2) == Data([0x00, 0x50]))

        let domainRequest = try SOCKS5CommandRequest(
            command: .connect,
            endpoint: SOCKS5Endpoint(address: SOCKS5Address(domain: "proxy.example"), port: 1080)
        )
        let domainFrame = try SOCKS5Codec.encodeCommandRequest(domainRequest)
        #expect(domainFrame.prefix(5) == Data([0x05, 0x01, 0x00, 0x03, 13]))
        #expect(domainFrame.suffix(2) == Data([0x04, 0x38]))
    }

    @Test
    func udpAssociateAllowsZeroClientPortButConnectDoesNot() throws {
        let endpoint = SOCKS5Endpoint(
            address: SOCKS5Address(ipAddress: try IPAddress("0.0.0.0")),
            port: 0
        )
        let request = try SOCKS5CommandRequest(command: .udpAssociate, endpoint: endpoint)
        #expect(try SOCKS5Codec.encodeCommandRequest(request).suffix(2) == Data([0, 0]))
        #expect(throws: SOCKS5CodecError.invalidPort(0)) {
            try SOCKS5CommandRequest(command: .connect, endpoint: endpoint)
        }
    }

    @Test
    func commandRepliesDecodeAndMapFailures() throws {
        let successFrame = Data([0x05, 0x00, 0x00, 0x01, 127, 0, 0, 1, 0x04, 0x38])
        let success = try SOCKS5Codec.decodeCommandReply(successFrame)
        #expect(success.code == .succeeded)
        #expect(success.boundEndpoint.address.ipAddress == (try IPAddress("127.0.0.1")))
        #expect(try success.requireSuccess().port == 1080)

        let failureFrame = Data([0x05, 0x05, 0x00, 0x01, 0, 0, 0, 0, 0, 0])
        let failure = try SOCKS5Codec.decodeCommandReply(failureFrame)
        #expect(failure.code == .connectionRefused)
        #expect(throws: SOCKS5CodecError.serverRejected(.connectionRefused)) {
            try failure.requireSuccess()
        }
    }

    @Test
    func udpDatagramsRoundTripEveryAddressKind() throws {
        let destinations = [
            SOCKS5Endpoint(address: SOCKS5Address(ipAddress: try IPAddress("203.0.113.8")), port: 53),
            SOCKS5Endpoint(address: SOCKS5Address(ipAddress: try IPAddress("2001:db8::53")), port: 443),
            SOCKS5Endpoint(address: try SOCKS5Address(domain: "dns.example"), port: 5353),
        ]
        let payload = Data([0xDE, 0xAD, 0xBE, 0xEF])

        for destination in destinations {
            let datagram = try SOCKS5UDPDatagram(destination: destination, payload: payload)
            let encoded = try SOCKS5Codec.encodeUDPDatagram(datagram)
            #expect(try SOCKS5Codec.decodeUDPDatagram(encoded) == datagram)
        }
    }

    @Test
    func invalidAndShortFramesAreRejected() throws {
        #expect(throws: SOCKS5CodecError.truncatedFrame(minimumExpected: 2, actual: 1)) {
            try SOCKS5Codec.decodeMethodSelection(Data([0x05]))
        }
        #expect(throws: SOCKS5CodecError.trailingData(1)) {
            try SOCKS5Codec.decodeMethodSelection(Data([0x05, 0x00, 0xAA]))
        }
        #expect(throws: SOCKS5CodecError.invalidVersion(4)) {
            try SOCKS5Codec.decodeCommandReply(Data([4, 0, 0, 1, 0, 0, 0, 0, 0, 0]))
        }
        #expect(throws: SOCKS5CodecError.invalidReservedByte(1)) {
            try SOCKS5Codec.decodeCommandReply(Data([5, 0, 1, 1, 0, 0, 0, 0, 0, 0]))
        }
        #expect(throws: SOCKS5CodecError.invalidAddressType(2)) {
            try SOCKS5Codec.decodeCommandReply(Data([5, 0, 0, 2, 0, 0]))
        }
        #expect(throws: SOCKS5CodecError.invalidReplyCode(9)) {
            try SOCKS5Codec.decodeCommandReply(Data([5, 9, 0, 1, 0, 0, 0, 0, 0, 0]))
        }
        #expect(throws: SOCKS5CodecError.invalidDomainLength(0)) {
            try SOCKS5Codec.decodeCommandReply(Data([5, 0, 0, 3, 0, 0, 0]))
        }
        #expect(throws: SOCKS5CodecError.invalidDomainEncoding) {
            try SOCKS5Codec.decodeCommandReply(Data([5, 0, 0, 3, 1, 0xFF, 0, 80]))
        }
    }

    @Test
    func udpValidationRejectsReservedFragmentedShortAndOversizedFrames() throws {
        #expect(throws: SOCKS5CodecError.truncatedFrame(minimumExpected: 4, actual: 3)) {
            try SOCKS5Codec.decodeUDPDatagram(Data([0, 0, 0]))
        }
        #expect(throws: SOCKS5CodecError.invalidReservedByte(1)) {
            try SOCKS5Codec.decodeUDPDatagram(Data([1, 0, 0, 1, 0, 0, 0, 0, 0, 53]))
        }
        #expect(throws: SOCKS5CodecError.fragmentedUDPDatagram(1)) {
            try SOCKS5Codec.decodeUDPDatagram(Data([0, 0, 1, 1, 0, 0, 0, 0, 0, 53]))
        }
        #expect(throws: SOCKS5CodecError.inputTooLarge(
            limit: SOCKS5Limits.maximumUDPDatagramBytes,
            actual: SOCKS5Limits.maximumUDPDatagramBytes + 1
        )) {
            try SOCKS5Codec.decodeUDPDatagram(
                Data(repeating: 0, count: SOCKS5Limits.maximumUDPDatagramBytes + 1)
            )
        }
    }

    @Test
    func domainAndDatagramConstructionEnforceBounds() throws {
        #expect(throws: SOCKS5CodecError.invalidDomainLength(0)) {
            try SOCKS5Address(domain: "")
        }
        #expect(throws: SOCKS5CodecError.invalidDomainLength(256)) {
            try SOCKS5Address(domain: String(repeating: "a", count: 256))
        }
        #expect(throws: SOCKS5CodecError.invalidDomain("bad\nname")) {
            try SOCKS5Address(domain: "bad\nname")
        }
        let zeroPort = SOCKS5Endpoint(
            address: SOCKS5Address(ipAddress: try IPAddress("127.0.0.1")),
            port: 0
        )
        #expect(throws: SOCKS5CodecError.invalidPort(0)) {
            try SOCKS5UDPDatagram(destination: zeroPort, payload: Data())
        }
    }

    private func request(command: SOCKS5Command, ip: String, port: UInt16) throws -> SOCKS5CommandRequest {
        try SOCKS5CommandRequest(
            command: command,
            endpoint: SOCKS5Endpoint(address: SOCKS5Address(ipAddress: IPAddress(ip)), port: port)
        )
    }
}
