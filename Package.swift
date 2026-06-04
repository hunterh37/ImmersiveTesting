// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ImmersiveTesting",
    platforms: [
        .visionOS(.v2),
        .iOS(.v18),
        .macOS(.v15),
    ],
    products: [
        // XCTest-free production layer: provider protocols, fakes, SceneEnvironment,
        // SceneBuilder, TestScene. Safe to link into the shipping app target.
        .library(name: "ImmersiveTestingRuntime", targets: ["ImmersiveTestingRuntime"]),
        // Full test-facing surface: assertions, harness, scene-state specs. Pulls in XCTest;
        // depend on this only from test targets. Re-exports the runtime.
        .library(name: "ImmersiveTesting", targets: ["ImmersiveTesting"]),
    ],
    targets: [
        .target(name: "ImmersiveTestingRuntime"),
        .target(name: "ImmersiveTesting", dependencies: ["ImmersiveTestingRuntime"]),
        .testTarget(
            name: "ImmersiveTestingTests",
            dependencies: ["ImmersiveTesting"]
        ),
    ]
)
