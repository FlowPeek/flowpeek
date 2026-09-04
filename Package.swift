// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "FlowPeek",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "FlowPeekCore", targets: ["FlowPeekCore"]),
        .executable(name: "FlowPeek", targets: ["FlowPeek"]),
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.9.2"),
    ],
    targets: [
        .target(name: "FlowPeekCore"),
        .executableTarget(
            name: "FlowPeek",
            dependencies: ["FlowPeekCore", .product(name: "Sparkle", package: "Sparkle")],
            resources: [.process("Resources")]
        ),
        .testTarget(name: "FlowPeekCoreTests", dependencies: ["FlowPeekCore"]),
    ]
)
