// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MClash",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "MClash", targets: ["MClashApp"]),
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
            name: "MClashNetworkShared",
            path: "Sources/MClashNetworkShared"
        ),
        .executableTarget(
            name: "MClashApp",
            dependencies: [
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
            ]
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
            name: "MClashTests",
            dependencies: ["MClashApp"],
            path: "Tests/MClashTests"
        ),
        .testTarget(
            name: "MClashNetworkSharedTests",
            dependencies: ["MClashNetworkShared"],
            path: "Tests/MClashNetworkSharedTests"
        )
    ]
)
