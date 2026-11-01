// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "JTKit",
    platforms: [
        .macOS(.v14),   // lowest target among the apps (Profile2Blueprint, Serial Number Reader); macOS only
    ],
    products: [
        .library(name: "JTKit", targets: ["JTKit"]),
        // Microsoft’s sign-in window for Intune. The only product that
        // depends on MSAL: apps without it ship nothing of MSAL.
        .library(name: "JTKitMSAL", targets: ["JTKitMSAL"]),
        // Test helpers for app test targets; never a dependency of JTKit itself.
        // Builds on JTKit (InMemorySecretStore is a JTKit SecretStore).
        .library(name: "JTKitTestSupport", targets: ["JTKitTestSupport"]),
        // UI test targets only (XCTest); doesn’t link JTKit. Includes
        // JTKitLiveCheck, for live UI tests.
        .library(name: "JTKitUITestSupport", targets: ["JTKitUITestSupport"]),
        // Live checks in an app’s unit test target only;
        // apps never ship it. Doesn’t link JTKit: its session goes into the
        // app’s RequestRecorder.
        .library(name: "JTKitLiveCheck", targets: ["JTKitLiveCheck"]),
        // The release check’s gateway for live UI tests (1.1.0, B1): built
        // and started by release-check-lib.sh, never by an app.
        .executable(name: "jtkit-live-gateway", targets: ["JTKitLiveGateway"]),
    ],
    dependencies: [
        // Pinned exactly; JTKitMSAL’s `MicrosoftSignIn.msalVersion` and its
        // license notice follow it.
        .package(url: "https://github.com/AzureAD/microsoft-authentication-library-for-objc", exact: "2.16.0"),
    ],
    targets: [
        .target(name: "JTKit"),
        .target(name: "JTKitMSAL", dependencies: [
            "JTKit",
            .product(name: "MSAL", package: "microsoft-authentication-library-for-objc"),
        ]),
        // Also JTKit’s own live checks for an app’s release check (they
        // need JTKit and the guarded network).
        .target(name: "JTKitTestSupport", dependencies: ["JTKit", "JTKitLiveCheck"]),
        // XCUITest’s API is main-actor bound in ways Swift 6 mode can’t
        // express for XCTestCase overrides; the app UI test targets use 5 too.
        // Live UI tests (1.1.0): the gateway decides every request of the
        // app under -JTKitLiveCheck with JTKitLiveCheck’s rules.
        .target(name: "JTKitUITestSupport", dependencies: ["JTKitLiveCheck"], swiftSettings: [.swiftLanguageMode(.v5)]),
        .target(name: "JTKitLiveCheck"),
        .executableTarget(name: "JTKitLiveGateway", dependencies: ["JTKitLiveCheck"]),
        // Fixtures are read from disk by path, not bundled
        .testTarget(name: "JTKitTests", dependencies: ["JTKit", "JTKitTestSupport", "JTKitUITestSupport", "JTKitLiveCheck"],
                    exclude: ["Fixtures"]),
        .testTarget(name: "JTKitLiveCheckTests", dependencies: ["JTKitLiveCheck", "JTKitTestSupport"]),
        .testTarget(name: "JTKitMSALTests", dependencies: ["JTKitMSAL"]),
    ]
)
