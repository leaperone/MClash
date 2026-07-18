import Foundation
import Testing

@Suite("Release packaging")
struct ReleasePackagingTests {
    private let appGroup = "5UAHRS482C.one.leaper.mclash"
    private let teamIdentifier = "5UAHRS482C"

    @Test("Host and Network Extension share the Mach service App Group")
    func machServiceUsesSharedAppGroup() throws {
        let hostEntitlements = try plist(
            at: repositoryRoot.appendingPathComponent(
                "Support/Signing/MClash-DeveloperID.entitlements"
            )
        )
        let extensionEntitlements = try plist(
            at: repositoryRoot.appendingPathComponent(
                "Support/NetworkExtension/MClashNetworkExtension.DeveloperID.entitlements"
            )
        )
        let extensionInfo = try plist(
            at: repositoryRoot.appendingPathComponent("Support/NetworkExtension/Info.plist")
        )

        for entitlements in [hostEntitlements, extensionEntitlements] {
            let groups = try #require(
                entitlements["com.apple.security.application-groups"] as? [String]
            )
            #expect(groups.contains(appGroup))
        }

        let networkExtension = try #require(
            extensionInfo["NetworkExtension"] as? [String: Any]
        )
        let machService = try #require(networkExtension["NEMachServiceName"] as? String)
        #expect(machService == "$(TeamIdentifierPrefix)one.leaper.mclash.network-extension")
    }

    @Test("Developer ID signatures declare identities required for provider IPC")
    func developerIDProviderIPCIdentities() throws {
        let hostEntitlements = try plist(
            at: repositoryRoot.appendingPathComponent(
                "Support/Signing/MClash-DeveloperID.entitlements"
            )
        )
        let extensionEntitlements = try plist(
            at: repositoryRoot.appendingPathComponent(
                "Support/NetworkExtension/MClashNetworkExtension.DeveloperID.entitlements"
            )
        )

        #expect(
            hostEntitlements["com.apple.application-identifier"] as? String
                == "\(teamIdentifier).one.leaper.mclash"
        )
        #expect(
            extensionEntitlements["com.apple.application-identifier"] as? String
                == "\(teamIdentifier).one.leaper.mclash.network-extension"
        )
        #expect(
            hostEntitlements["com.apple.developer.team-identifier"] as? String
                == teamIdentifier
        )
        #expect(
            extensionEntitlements["com.apple.developer.team-identifier"] as? String
                == teamIdentifier
        )
    }

    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func plist(at url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        return try #require(
            PropertyListSerialization.propertyList(from: data, format: nil)
                as? [String: Any]
        )
    }
}
