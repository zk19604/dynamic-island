// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "IslandClip",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "IslandClip", targets: ["IslandClip"]),
        // Tiny helper loaded by /usr/bin/perl to read "Now Playing" info.
        // See Sources/IslandMediaHelper/IslandMediaHelper.m for why.
        .library(name: "IslandMediaHelper", type: .dynamic, targets: ["IslandMediaHelper"]),
    ],
    targets: [
        .target(name: "IslandClipCore"),
        .executableTarget(
            name: "IslandClip",
            dependencies: ["IslandClipCore"]
        ),
        .target(
            name: "IslandMediaHelper",
            linkerSettings: [.linkedFramework("Foundation")]
        ),
        .testTarget(
            name: "IslandClipCoreTests",
            dependencies: ["IslandClipCore"]
        ),
    ]
)
