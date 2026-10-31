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
    targets: [
        .target(name: "BridgeCore"),
        .testTarget(name: "BridgeCoreTests", dependencies: ["BridgeCore"]),
    ]
)
