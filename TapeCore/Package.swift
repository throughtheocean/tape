// swift-tools-version:5.10
import PackageDescription

let strict: [SwiftSetting] = [.enableExperimentalFeature("StrictConcurrency")]

let package = Package(
    name: "TapeCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "TapeCore", targets: ["TapeCore"]),
        .library(name: "HardwarePresets", targets: ["HardwarePresets"]),
    ],
    targets: [
        .target(name: "TapeAtomics"),
        .target(name: "HardwarePresets", swiftSettings: strict),
        .target(name: "TapeCore", dependencies: ["TapeAtomics", "HardwarePresets"], swiftSettings: strict),
        .testTarget(name: "TapeCoreTests", dependencies: ["TapeCore", "HardwarePresets"], resources: [.copy("Fixtures")],
                    swiftSettings: strict),
    ]
)
