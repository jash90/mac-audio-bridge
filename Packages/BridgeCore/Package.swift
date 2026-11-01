// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "BridgeCore",
    platforms: [
        .macOS("15.0"),
        .iOS(.v18),
    ],
    products: [
        .library(name: "BridgeCore", targets: ["BridgeCore"]),
    ],
    dependencies: [
        // Vendored libopus 1.5.2 (see ThirdParty/opus/Package.swift).
        .package(path: "../../ThirdParty/opus"),
    ],
    targets: [
        // Non-variadic ctl wrappers so Swift can configure libopus.
        .target(
            name: "COpusShim",
            dependencies: [.product(name: "COpus", package: "opus")],
            cSettings: [.unsafeFlags(["-Wall", "-Wextra"])]
        ),
        .target(
            name: "BridgeCore",
            dependencies: [
                .product(name: "COpus", package: "opus"),
                "COpusShim",
            ]
        ),
        .testTarget(name: "BridgeCoreTests", dependencies: ["BridgeCore"]),
    ]
)
