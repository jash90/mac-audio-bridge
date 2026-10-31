// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "BridgeCore",
    platforms: [
        .macOS("14.2"),
        .iOS(.v17),
    ],
    products: [
        .library(name: "BridgeCore", targets: ["BridgeCore"]),
    ],
    targets: [
        .target(name: "BridgeCore"),
        .testTarget(name: "BridgeCoreTests", dependencies: ["BridgeCore"]),
    ]
)
