// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AgentMeter",
    platforms: [
        .macOS(.v14)
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0")
    ],
    targets: [
        .target(
            name: "AgentStatusCore",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .executableTarget(
            name: "AgentMeter",
            dependencies: [
                .product(name: "Sparkle", package: "Sparkle"),
                "AgentStatusCore"
            ],
            resources: [
                .copy("Resources/embedded-pricing.json")
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .executableTarget(
            name: "AgentMeterHook",
            dependencies: ["AgentStatusCore"],
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .testTarget(
            name: "AgentMeterTests",
            dependencies: ["AgentMeter", "AgentStatusCore"],
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        )
    ]
)
