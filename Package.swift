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

        // Off-screen RealityView renderer. Add to your iOS/macOS test targets.
        // Pair with the MCP server so coding agents can see what was rendered.
        .library(name: "ImmersiveTestingRenderer", targets: ["ImmersiveTestingRenderer"]),

        // Stdio MCP server that serves render snapshots to coding agents.
        // Run with: swift run ImmersiveTestingMCP
        .executable(name: "ImmersiveTestingMCP", targets: ["ImmersiveTestingMCP"]),

        // macOS capture app: edit Sources/ImmersiveCaptureApp/Scene.swift, then
        // run `swift run ImmersiveCaptureApp` — PNG path is printed to stdout.
        .executable(name: "ImmersiveCaptureApp", targets: ["ImmersiveCaptureApp"]),
    ],
    targets: [
        .target(name: "ImmersiveTestingRuntime"),
        .target(name: "ImmersiveTesting", dependencies: ["ImmersiveTestingRuntime"]),
        .target(
            name: "ImmersiveTestingRenderer",
            dependencies: [],
            path: "Sources/ImmersiveTestingRenderer"
        ),
        .executableTarget(
            name: "ImmersiveTestingMCP",
            dependencies: [],
            path: "Sources/ImmersiveTestingMCP"
        ),
        .executableTarget(
            name: "ImmersiveCaptureApp",
            dependencies: [],
            path: "Sources/ImmersiveCaptureApp"
        ),
        .testTarget(
            name: "ImmersiveTestingTests",
            dependencies: ["ImmersiveTesting"]
        ),
    ]
)
