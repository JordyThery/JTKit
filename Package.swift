// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "JTKit",
    platforms: [
        .macOS(.v14),   // lowest target among the apps (Profile2Blueprint, Serial Number Reader)
        .iOS(.v17),     // Device Assist
    ],
    products: [
        .library(name: "JTKit", targets: ["JTKit"]),
    ],
    targets: [
        .target(name: "JTKit"),
        .testTarget(name: "JTKitTests", dependencies: ["JTKit"]),
    ]
)
