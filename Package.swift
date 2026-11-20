// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MacSweep",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "MacSweepCore", targets: ["MacSweepCore"]),
        .executable(name: "MacSweepApp", targets: ["MacSweepApp"]),
    ],
    targets: [
        .target(
            name: "MacSweepCore",
            path: "Sources/MacSweepCore"
        ),
        .executableTarget(
            name: "MacSweepApp",
            dependencies: ["MacSweepCore"],
            path: "Sources/MacSweepApp",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "MacSweepChecks",
            dependencies: ["MacSweepCore"],
            path: "Tests/MacSweepChecks"
        ),
    ]
)
