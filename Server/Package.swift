// swift-tools-version: 6.0
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

/// NOTE: gRPC Swift 2 requires macOS 15+ for its Swift 6 concurrency features.
/// The deployment target is set to macOS 15 to ensure compatibility.
let package = Package(
    name: "MacosUseServer",
    platforms: [
        .macOS(.v15),
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
        .package(url: "https://github.com/grpc/grpc-swift-extras.git", from: "2.0.0"),
        .package(name: "MacosUseSDK", path: "../"),
    ],
    targets: [
        // Target for the generated Swift Protobuf and gRPC stubs
        // This makes the generated code available to the server target
        .target(
            name: "MacosUseProto",
            dependencies: [
                .product(name: "GRPCProtobuf", package: "grpc-swift-protobuf"),
            ],
            path: "Sources/MacosUseProto",
            // The expr protos are not used; avoid dangling excludes which
            // trigger warnings by only including the directories we need.
            sources: ["macosusesdk/", "google/", "BundleMarker.swift"],
            resources: [
                .copy("DescriptorSets"),
            ],
            swiftSettings: [
                .unsafeFlags(["-Xfrontend", "-warn-concurrency"]),
            ],
        ),
        .executableTarget(
            name: "MacosUseServer",
            dependencies: [
                .product(name: "GRPCCore", package: "grpc-swift-2"),
                .product(name: "GRPCNIOTransportHTTP2", package: "grpc-swift-nio-transport"),
                .product(name: "GRPCReflectionService", package: "grpc-swift-extras"),
                "MacosUseSDK",
                "MacosUseProto", // Add dependency on the generated protos
            ],
            path: "Sources/MacosUseServer",
            resources: [
                .copy("DescriptorSets"),
            ],
            swiftSettings: [
                .unsafeFlags(["-Xfrontend", "-warn-concurrency"]),
            ],
        ),
        .testTarget(
            name: "MacosUseServerTests",
            dependencies: ["MacosUseServer"],
        ),
    ],
)
