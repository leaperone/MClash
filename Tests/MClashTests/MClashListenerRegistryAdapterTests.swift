import Foundation
import Testing
@testable import MClash

@Suite("MClash listener registry adapter")
struct MClashListenerRegistryAdapterTests {
    @Test("Configuration entrances project to native entries without importing Mihomo settings")
    func projectsEntrances() throws {
        let httpID = EntranceID(rawValue: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!)
        let appID = EntranceID(rawValue: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!)
        let groupID = ProxyGroupID(rawValue: UUID(uuidString: "99999999-8888-7777-6666-555555555555")!)
        let entrances = [
            Entrance(
                id: httpID,
                name: "Work HTTP",
                kind: .http,
                enabled: true,
                bindAddress: "127.0.0.1",
                port: 18_080,
                defaultAction: .proxyGroup(groupID)
            ),
            Entrance(id: appID, name: "Applications", kind: .appRouting, enabled: true),
        ]
        let registry = try MClashListenerRegistryAdapter.registry(from: entrances)
        #expect(registry.listeners.count == 2)
        #expect(registry.listener(id: httpID.rawValue)?.route == .outbound(.group(groupID.rawValue.uuidString)))
        #expect(registry.listener(id: appID.rawValue)?.endpoint == nil)
    }
}
