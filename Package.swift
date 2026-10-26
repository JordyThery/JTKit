// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "JTKit",
    platforms: [
        .macOS(.v14),   // lowest target among the apps (Profile2Blueprint, Serial Number Reader); macOS only
    ],
    products: [
        .library(name: "JTKit", targets: ["JTKit"]),
        // Test helpers for app test targets; never a dependency of JTKit itself.
        // Builds on JTKit (InMemorySecretStore is a JTKit SecretStore).
        .library(name: "JTKitTestSupport", targets: ["JTKitTestSupport"]),
    ],
    targets: [
        .target(name: "JTKit"),
        .target(name: "JTKitTestSupport", dependencies: ["JTKit"]),
        // Fixtures are read from disk by path, not bundled
        .testTarget(name: "JTKitTests", dependencies: ["JTKit", "JTKitTestSupport"], exclude: ["Fixtures"]),
    ]
)
