// swift-tools-version: 6.0
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "MacosUseServer",
    platforms: [
        .macOS(.v12)
    ],
    products: [
        .executable(
            name: "MacosUseServer",
            targets: ["MacosUseServer"])
    ],
    dependencies: [
        .package(url: "https://github.com/grpc/grpc-swift.git", from: "1.23.0"),
        .package(name: "MacosUseSDK", path: "../")
    ],
    targets: [
        .executableTarget(
            name: "MacosUseServer",
            dependencies: [
                .product(name: "GRPC", package: "grpc-swift"),
                "MacosUseSDK"
            ],
            path: "Sources/MacosUseServer"
        ),
        .testTarget(
            name: "MacosUseServerTests",
            dependencies: ["MacosUseServer"]
        )
    ]
)
