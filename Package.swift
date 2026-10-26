// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "JTKit",
    platforms: [
        .macOS(.v14),   // lowest target among the apps (Profile2Blueprint, Serial Number Reader); macOS only
    ],
    products: [
        .library(name: "JTKit", targets: ["JTKit"]),
        // Microsoft's sign-in window for Intune (ROADMAP step 8). The only
        // product that depends on MSAL: apps without it ship nothing of MSAL.
        .library(name: "JTKitMSAL", targets: ["JTKitMSAL"]),
        // Test helpers for app test targets; never a dependency of JTKit itself.
        // Builds on JTKit (InMemorySecretStore is a JTKit SecretStore).
        .library(name: "JTKitTestSupport", targets: ["JTKitTestSupport"]),
    ],
    dependencies: [
        // Pinned exactly (approved by Jordy on 2026-10-26); JTKitMSAL's
        // `MicrosoftSignIn.msalVersion` and its licence notice follow it.
        .package(url: "https://github.com/AzureAD/microsoft-authentication-library-for-objc", exact: "2.16.0"),
    ],
    targets: [
        .target(name: "JTKit"),
        .target(name: "JTKitMSAL", dependencies: [
            "JTKit",
            .product(name: "MSAL", package: "microsoft-authentication-library-for-objc"),
        ]),
        .target(name: "JTKitTestSupport", dependencies: ["JTKit"]),
        // Fixtures are read from disk by path, not bundled
        .testTarget(name: "JTKitTests", dependencies: ["JTKit", "JTKitTestSupport"], exclude: ["Fixtures"]),
        .testTarget(name: "JTKitMSALTests", dependencies: ["JTKitMSAL"]),
    ]
)
