// swift-tools-version:5.10
import PackageDescription

let strict: [SwiftSetting] = [.enableExperimentalFeature("StrictConcurrency")]

let package = Package(
    name: "TapeCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "TapeCore", targets: ["TapeCore"]),
    ],
    targets: [
        .target(name: "TapeAtomics"),
        .target(name: "TapeCore", dependencies: ["TapeAtomics"], swiftSettings: strict),
        .testTarget(name: "TapeCoreTests", dependencies: ["TapeCore"], swiftSettings: strict),
    ]
)
