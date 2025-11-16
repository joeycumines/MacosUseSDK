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
        // gRPC Swift 2 officially targets macOS 15+, but this package
        // maintains a lower deployment target while relying on
        // `-disable-availability-checking` for guarded APIs.
        .macOS(.v12),
    ],
    products: [
        .executable(
            name: "MacosUseServer",
            targets: ["MacosUseServer"],
        ),
    ],
    dependencies: [
        // gRPC Swift 2 core, transport, and Protobuf integration
        .package(url: "https://github.com/grpc/grpc-swift-2.git", from: "2.0.0"),
        .package(url: "https://github.com/grpc/grpc-swift-protobuf.git", from: "2.0.0"),
        .package(url: "https://github.com/grpc/grpc-swift-nio-transport.git", from: "2.0.0"),
        .package(url: "https://github.com/apple/swift-atomics.git", from: "1.0.0"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.0.0"),
        .package(url: "https://github.com/apple/swift-nio-http2.git", from: "1.0.0"),
        .package(name: "MacosUseSDK", path: "../"),
    ],
    targets: [
        // Target for the generated Swift Protobuf and gRPC stubs
        // This makes the generated code available to the server target
        .target(
            name: "MacosUseSDKProtos",
            dependencies: [
                .product(name: "GRPCProtobuf", package: "grpc-swift-protobuf"),
                .product(name: "Atomics", package: "swift-atomics"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOHTTP2", package: "swift-nio-http2"),
            ],
            path: "Sources/MacosUseSDKProtos",
            // The expr protos are not used; avoid dangling excludes which
            // trigger warnings by only including the directories we need.
            sources: ["macosusesdk/", "google/"],
            swiftSettings: [
                .unsafeFlags(["-Xfrontend", "-disable-availability-checking"]),
                .unsafeFlags(["-Xfrontend", "-warn-concurrency"]),
            ],
        ),

        .executableTarget(
            name: "MacosUseServer",
            dependencies: [
                .product(name: "GRPCCore", package: "grpc-swift-2"),
                .product(name: "GRPCNIOTransportHTTP2", package: "grpc-swift-nio-transport"),
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
