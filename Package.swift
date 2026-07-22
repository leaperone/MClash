// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MClash",
    defaultLocalization: "en",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "MClash", targets: ["MClashApp"]),
        .library(
            name: "MClashAutomationProtocol",
            targets: ["MClashAutomationProtocol"]
        ),
        .executable(name: "mclashctl", targets: ["MClashCLI"]),
        .library(name: "MClashNetworkShared", targets: ["MClashNetworkShared"]),
        .executable(name: "MClashNetworkExtension", targets: ["MClashNetworkExtension"])
    ],
    dependencies: [
        .package(
            url: "https://github.com/sparkle-project/Sparkle",
            exact: "2.9.4"
        )
    ],
    targets: [
        .target(
            name: "MClashAutomationProtocol",
            path: "Sources/MClashAutomationProtocol",
            linkerSettings: [.linkedFramework("Security")]
        ),
        .target(
            name: "MClashNetworkShared",
            path: "Sources/MClashNetworkShared"
        ),
        .executableTarget(
            name: "MClashApp",
            dependencies: [
                "MClashAutomationProtocol",
                "MClashNetworkShared",
                .product(name: "Sparkle", package: "Sparkle")
            ],
            path: "Sources/MClashApp",
            resources: [.process("Resources")],
            linkerSettings: [
                .linkedFramework("ServiceManagement"),
                .linkedFramework("NetworkExtension"),
                .linkedFramework("Security"),
                .linkedFramework("SystemExtensions"),
                .linkedFramework("UserNotifications"),
                .linkedLibrary("sqlite3"),
            ]
        ),
        .executableTarget(
            name: "MClashCLI",
            dependencies: ["MClashAutomationProtocol"],
            path: "Sources/MClashCLI"
        ),
        .executableTarget(
            name: "MClashNetworkExtension",
            dependencies: ["MClashNetworkShared"],
            path: "Sources/MClashNetworkExtension",
            linkerSettings: [
                .linkedFramework("Network"),
                .linkedFramework("NetworkExtension"),
                .linkedFramework("Security"),
                .linkedLibrary("bsm"),
            ]
        ),
        .testTarget(
            name: "MClashAutomationProtocolTests",
            dependencies: ["MClashAutomationProtocol"],
            path: "Tests/MClashAutomationProtocolTests"
        ),
        .testTarget(
            name: "MClashTests",
            dependencies: ["MClashApp", "MClashAutomationProtocol"],
            path: "Tests/MClashTests"
        ),
        .testTarget(
            name: "MClashNetworkSharedTests",
            dependencies: ["MClashNetworkShared"],
            path: "Tests/MClashNetworkSharedTests"
        ),
        .testTarget(
            name: "MClashNetworkExtensionTests",
            dependencies: ["MClashNetworkExtension", "MClashNetworkShared"],
            path: "Tests/MClashNetworkExtensionTests"
        )
    ]
)
