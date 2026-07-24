import Foundation
import Testing
@testable import MClashNetworkShared

@Suite("Routing profile identity")
struct RoutingProfileIDTests {
    @Test("UUIDs use one stable lowercase string representation")
    func canonicalRepresentation() throws {
        let identifier = try RoutingProfileID(
            rawValue: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"
        )

        #expect(identifier.rawValue == "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")
        #expect(identifier.description == identifier.rawValue)
        #expect(identifier.uuid == UUID(
            uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
        ))
        #expect(
            String(decoding: try JSONEncoder().encode(identifier), as: UTF8.self)
                == "\"aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee\""
        )
    }

    @Test("Construction and decoding reject non-UUID profile identifiers")
    func rejectsInvalidValues() {
        #expect(throws: RoutingProfileIDError.invalidUUID("profile-a")) {
            try RoutingProfileID(rawValue: "profile-a")
        }
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(
                RoutingProfileID.self,
                from: Data("\"profile-a\"".utf8)
            )
        }
    }
}
