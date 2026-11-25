// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MacSweep",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "MacSweepCore", targets: ["MacSweepCore"]),
        .library(name: "MacSweepUI", targets: ["MacSweepUI"]),
        .executable(name: "MacSweepApp", targets: ["MacSweepApp"]),
    ],
    targets: [
        .target(
            name: "MacSweepCore",
            path: "Sources/MacSweepCore"
        ),
        .target(
            name: "MacSweepUI",
            dependencies: ["MacSweepCore"],
            path: "Sources/MacSweepApp",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "MacSweepApp",
            dependencies: ["MacSweepCore", "MacSweepUI"],
            path: "Sources/MacSweepAppEntry",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "MacSweepChecks",
            dependencies: ["MacSweepCore", "MacSweepUI"],
            path: "Tests/MacSweepChecks"
        ),
    ]
)
