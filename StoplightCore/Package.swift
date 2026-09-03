// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "StoplightCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "StoplightCore", targets: ["StoplightCore"]),
    ],
    targets: [
        .target(
            name: "StoplightCore",
            swiftSettings: [.enableExperimentalFeature("StrictConcurrency")]
        ),
        .testTarget(name: "StoplightCoreTests", dependencies: ["StoplightCore"]),
    ]
)
