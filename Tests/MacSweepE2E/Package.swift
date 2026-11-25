// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MacSweepE2E",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "E2EHarness", targets: ["E2EHarness"]),
        .executable(name: "E2EBaselineProbe", targets: ["E2EBaselineProbe"]),
        .executable(name: "E2EM1Probe", targets: ["E2EM1Probe"]),
        .executable(name: "E2EM2Probe", targets: ["E2EM2Probe"]),
        .executable(name: "E2EM3Probe", targets: ["E2EM3Probe"]),
        .executable(name: "E2EM4Probe", targets: ["E2EM4Probe"]),
        .executable(name: "E2ETier3Tier4Probe", targets: ["E2ETier3Tier4Probe"]),
    ],
    dependencies: [
        .package(path: "../.."),
    ],
    targets: [
        .target(
            name: "E2EHarness",
            dependencies: [],
            path: "Sources/E2EHarness"
        ),
        .executableTarget(
            name: "E2EBaselineProbe",
            dependencies: [
                "E2EHarness",
                .product(name: "MacSweepCore", package: "MacSweep"),
            ],
            path: "Sources/E2EBaselineProbe"
        ),
        .executableTarget(
            name: "E2EM1Probe",
            dependencies: [
                "E2EHarness",
                .product(name: "MacSweepCore", package: "MacSweep"),
            ],
            path: "Sources/E2EM1Probe"
        ),
        .executableTarget(
            name: "E2EM2Probe",
            dependencies: [
                "E2EHarness",
                .product(name: "MacSweepCore", package: "MacSweep"),
            ],
            path: "Sources/E2EM2Probe"
        ),
        .executableTarget(
            name: "E2EM3Probe",
            dependencies: [
                "E2EHarness",
                .product(name: "MacSweepCore", package: "MacSweep"),
            ],
            path: "Sources/E2EM3Probe"
        ),
        .executableTarget(
            name: "E2EM4Probe",
            dependencies: [
                "E2EHarness",
                .product(name: "MacSweepCore", package: "MacSweep"),
            ],
            path: "Sources/E2EM4Probe"
        ),
        .executableTarget(
            name: "E2ETier3Tier4Probe",
            dependencies: [
                "E2EHarness",
                .product(name: "MacSweepCore", package: "MacSweep"),
            ],
            path: "Sources/E2ETier3Tier4Probe"
        ),
    ]
)
