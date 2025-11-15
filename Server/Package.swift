// swift-tools-version: 6.0
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

// NOTE: Availability checking is disabled via unsafeFlags to support Swift 6.2
// concurrency features while maintaining macOS 12 compatibility.
// The server has been tested on macOS 14+ and requires macOS 12 minimum.
// Runtime crashes on older macOS versions are possible if newer APIs are used.
let package = Package(
    name: "MacosUseServer",
    platforms: [
        .macOS(.v12),
    ],
    products: [
        .executable(
            name: "MacosUseServer",
            targets: ["MacosUseServer"],
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/grpc/grpc-swift.git", from: "1.23.0"),
        .package(name: "MacosUseSDK", path: "../"),
    ],
    targets: [
        // Target for the generated Swift Protobuf and gRPC stubs
        // This makes the generated code available to the server target
        .target(
            name: "MacosUseSDKProtos",
            dependencies: [
                .product(name: "GRPC", package: "grpc-swift"),
            ],
            path: "Sources/MacosUseSDKProtos",
            exclude: ["google/api/expr/v1beta1/"],
            sources: ["macosusesdk/", "google/"],
            swiftSettings: [
                .unsafeFlags(["-Xfrontend", "-disable-availability-checking"]),
                .unsafeFlags(["-Xfrontend", "-warn-concurrency"]),
            ],
        ),

        .executableTarget(
            name: "MacosUseServer",
            dependencies: [
                .product(name: "GRPC", package: "grpc-swift"),
                "MacosUseSDK",
                "MacosUseSDKProtos", // Add dependency on the generated protos
            ],
            path: "Sources/MacosUseServer",
            swiftSettings: [
                .unsafeFlags(["-Xfrontend", "-disable-availability-checking"]),
                .unsafeFlags(["-Xfrontend", "-warn-concurrency"]),
            ],
        ),
        .testTarget(
            name: "MacosUseServerTests",
            dependencies: ["MacosUseServer"],
        ),
    ],
)
