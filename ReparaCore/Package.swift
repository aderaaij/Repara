// swift-tools-version: 6.2
import PackageDescription

/// The part of Repara with hard-won correctness properties: coordinate
/// projection, the portal's wire shapes, PII stripping, taxonomy resolution and
/// payload assembly.
///
/// It deliberately imports neither UIKit/SwiftUI nor anything to do with the
/// Claude API, so `swift test` exercises all of it on a Mac with no device, no
/// simulator and no network.
let package = Package(
    name: "ReparaCore",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "ReparaCore", targets: ["ReparaCore"])
    ],
    targets: [
        .target(
            name: "ReparaCore",
            resources: [.process("Resources")]
        ),
        .testTarget(
            name: "ReparaCoreTests",
            dependencies: ["ReparaCore"],
            resources: [.process("Fixtures")]
        ),
    ]
)
