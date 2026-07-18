import Foundation
@testable import MClashApp
import Testing
import UniformTypeIdentifiers

@Suite("Release packaging")
struct ReleasePackagingTests {
    private let teamIdentifier = "5UAHRS482C"

    @Test("Mach service is a child of the shared macOS App Group")
    func machServiceUsesSharedAppGroupPrefix() throws {
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

        let expectedAppGroup = "\(teamIdentifier).one.leaper.mclash"
        let hostGroups = try #require(
            hostEntitlements["com.apple.security.application-groups"] as? [String]
        )
        let extensionGroups = try #require(
            extensionEntitlements["com.apple.security.application-groups"] as? [String]
        )
        #expect(hostGroups.contains(expectedAppGroup))
        #expect(extensionGroups.contains(expectedAppGroup))

        let networkExtension = try #require(
            extensionInfo["NetworkExtension"] as? [String: Any]
        )
        let machService = try #require(networkExtension["NEMachServiceName"] as? String)
        #expect(machService == "$(TeamIdentifierPrefix)one.leaper.mclash.network-extension")
        #expect(networkExtension["NEProviderClasses"] != nil)
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

    @Test("Host bundle registers the Proxifier PPX file type")
    func hostRegistersProxifierProfileType() throws {
        #expect(
            UTType.proxifierProfile.identifier
                == "one.leaper.mclash.proxifier-profile"
        )

        let hostInfo = try plist(at: repositoryRoot.appendingPathComponent("Support/Info.plist"))
        let declarations = try #require(
            hostInfo["UTImportedTypeDeclarations"] as? [[String: Any]]
        )
        let declaration = try #require(declarations.first(where: {
            $0["UTTypeIdentifier"] as? String
                == "one.leaper.mclash.proxifier-profile"
        }))
        let conformsTo = try #require(declaration["UTTypeConformsTo"] as? [String])
        #expect(conformsTo.contains("public.xml"))

        let tags = try #require(declaration["UTTypeTagSpecification"] as? [String: Any])
        let extensions = try #require(tags["public.filename-extension"] as? [String])
        #expect(extensions.contains("ppx"))
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
