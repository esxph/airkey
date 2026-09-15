// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "airKey",
    platforms: [
        .macOS(.v13),
    ],
    targets: [
        .executableTarget(
            name: "airKey",
            resources: [.process("Resources")],
            linkerSettings: [
                .linkedFramework("AVFoundation"),
                .linkedFramework("Vision"),
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
            ]
        ),
        .testTarget(name: "airKeyTests", dependencies: ["airKey"]),
    ]
)
