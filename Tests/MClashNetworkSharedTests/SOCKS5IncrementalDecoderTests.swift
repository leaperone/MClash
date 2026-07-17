import Foundation
@testable import MClashNetworkShared
import Testing

@Suite("SOCKS5 incremental decoders")
struct SOCKS5IncrementalDecoderTests {
    @Test
    func methodSelectionParsesBytewiseAndPreservesRemainder() throws {
        var decoder = SOCKS5MethodSelectionDecoder()
        #expect(try decoder.append(Data([0x05])) == nil)
        let selection = try decoder.append(Data([0x02, 0xCA, 0xFE]))
        #expect(selection?.method == .usernamePassword)
        #expect(decoder.remainingData == Data([0xCA, 0xFE]))
        #expect(decoder.isComplete)
        #expect(throws: SOCKS5CodecError.decoderAlreadyCompleted) {
            try decoder.append(Data())
        }
    }

    @Test
    func authResponseRejectsInvalidVersionImmediately() {
        var decoder = SOCKS5UsernamePasswordResponseDecoder()
        #expect(throws: SOCKS5CodecError.invalidUsernamePasswordVersion(5)) {
            try decoder.append(Data([0x05]))
        }
    }

    @Test
    func commandReplyParsesAtEverySplitPoint() throws {
        let domain = Array("relay.example".utf8)
        let frame = Data([0x05, 0x00, 0x00, 0x03, UInt8(domain.count)] + domain + [0x23, 0x82])

        for split in 0 ... frame.count {
            var decoder = SOCKS5CommandReplyDecoder()
            let first = Data(frame.prefix(split))
            let second = Data(frame.dropFirst(split))
            let early = try decoder.append(first)
            if split < frame.count {
                #expect(early == nil)
                let reply = try decoder.append(second)
                #expect(reply?.boundEndpoint.address.domain == "relay.example")
                #expect(reply?.boundEndpoint.port == 9090)
            } else {
                #expect(early?.boundEndpoint.port == 9090)
            }
        }
    }

    @Test
    func commandReplyPreservesCoalescedProxyPayload() throws {
        let reply = Data([0x05, 0x00, 0x00, 0x01, 127, 0, 0, 1, 0x04, 0x38])
        let payload = Data("HTTP/1.1 200 OK\r\n".utf8)
        var decoder = SOCKS5CommandReplyDecoder()

        let parsed = try decoder.append(reply + payload)
        #expect(parsed?.code == .succeeded)
        #expect(decoder.remainingData == payload)
    }

    @Test
    func commandReplyRejectsMalformedPrefixBeforeCompletion() throws {
        var badVersion = SOCKS5CommandReplyDecoder()
        #expect(throws: SOCKS5CodecError.invalidVersion(4)) {
            try badVersion.append(Data([4]))
        }

        var badReserved = SOCKS5CommandReplyDecoder()
        #expect(throws: SOCKS5CodecError.invalidReservedByte(2)) {
            try badReserved.append(Data([5, 0, 2]))
        }

        var badReply = SOCKS5CommandReplyDecoder()
        #expect(throws: SOCKS5CodecError.invalidReplyCode(9)) {
            try badReply.append(Data([5, 9]))
        }

        var badAddressType = SOCKS5CommandReplyDecoder()
        #expect(throws: SOCKS5CodecError.invalidAddressType(9)) {
            try badAddressType.append(Data([5, 0, 0, 9]))
        }
    }

    @Test
    func incompleteDomainWaitsForAllAddressAndPortBytes() throws {
        var decoder = SOCKS5CommandReplyDecoder()
        #expect(try decoder.append(Data([5, 0, 0, 3])) == nil)
        #expect(try decoder.append(Data([3, 0x61, 0x62])) == nil)
        #expect(try decoder.append(Data([0x63, 0])) == nil)
        let parsed = try decoder.append(Data([80]))
        #expect(parsed?.boundEndpoint.address.domain == "abc")
        #expect(parsed?.boundEndpoint.port == 80)
    }

    @Test
    func everyProperPrefixOfRepliesAndDatagramsIsHandledAsIncomplete() throws {
        let replies = [
            Data([5, 0, 0, 1, 192, 0, 2, 1, 0, 80]),
            Data([5, 0, 0, 4] + Array(repeating: 0, count: 15) + [1, 0, 80]),
            Data([5, 0, 0, 3, 3, 0x61, 0x62, 0x63, 0, 80]),
        ]

        for reply in replies {
            for length in 0 ..< reply.count {
                var decoder = SOCKS5CommandReplyDecoder()
                #expect(try decoder.append(Data(reply.prefix(length))) == nil)
            }
        }

        let datagram = try SOCKS5Codec.encodeUDPDatagram(
            SOCKS5UDPDatagram(
                destination: SOCKS5Endpoint(
                    address: SOCKS5Address(ipAddress: IPAddress("192.0.2.1")),
                    port: 53
                ),
                payload: Data([1, 2, 3])
            )
        )
        // The header has no payload length, so a frame is complete once its endpoint is complete.
        for length in 0 ..< 10 {
            #expect(throws: SOCKS5CodecError.self) {
                try SOCKS5Codec.decodeUDPDatagram(Data(datagram.prefix(length)))
            }
        }
    }

    @Test
    func boundedBufferRejectsSingleAndCumulativeOversizeInput() throws {
        var single = SOCKS5CommandReplyDecoder()
        #expect(throws: SOCKS5CodecError.inputTooLarge(
            limit: SOCKS5Limits.maximumStreamInputBytes,
            actual: SOCKS5Limits.maximumStreamInputBytes + 1
        )) {
            try single.append(Data(repeating: 0, count: SOCKS5Limits.maximumStreamInputBytes + 1))
        }

        var cumulative = SOCKS5CommandReplyDecoder()
        // A valid prefix that deliberately declares a 255-byte domain but never completes.
        #expect(try cumulative.append(Data([5, 0, 0, 3, 255])) == nil)
        #expect(throws: SOCKS5CodecError.inputTooLarge(
            limit: SOCKS5Limits.maximumStreamInputBytes,
            actual: SOCKS5Limits.maximumStreamInputBytes + 5
        )) {
            try cumulative.append(
                Data(repeating: 0x61, count: SOCKS5Limits.maximumStreamInputBytes)
            )
        }
    }
}
