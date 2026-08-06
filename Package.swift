// swift-tools-version: 6.0
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "MacosUseSDK",
    platforms: [
        .macOS(.v12),
    ],
    products: [
        .library(
            name: "MacosUseSDK",
            targets: ["MacosUseSDK"],
        ),
    ],
    dependencies: [
        // Add any external package dependencies here later if needed
    ],
    targets: [
        // Targets are the basic building blocks of a package, defining a module or a test suite.
        // Targets can depend on other targets in this package and products from dependencies.
        .target(
            name: "MacosUseSDK",
            dependencies: [],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ApplicationServices"),
            ],
        ),
        .testTarget(
            name: "MacosUseSDKTests",
            dependencies: ["MacosUseSDK"],
        ),
    ],
)
