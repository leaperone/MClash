// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MClash",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "MClash", targets: ["MClashApp"])
    ],
    dependencies: [
        .package(
            url: "https://github.com/sparkle-project/Sparkle",
            exact: "2.9.4"
        )
    ],
    targets: [
        .executableTarget(
            name: "MClashApp",
            dependencies: [
                .product(name: "Sparkle", package: "Sparkle")
            ],
            path: "Sources/MClashApp",
            resources: [.process("Resources")],
            linkerSettings: [
                .linkedFramework("ServiceManagement"),
                .linkedFramework("UserNotifications"),
            ]
        ),
        .testTarget(
            name: "MClashTests",
            dependencies: ["MClashApp"],
            path: "Tests/MClashTests"
        )
    ]
)
