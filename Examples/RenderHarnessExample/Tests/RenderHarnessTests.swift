import XCTest
import SwiftUI
import RealityKit
import ImmersiveTestingRenderer
@testable import RenderHarnessExample

// Agent workflow:
//   1. Run this test in background: xcodebuild test ... (Bash run_in_background: true)
//   2. The test prints: "RenderHarness waiting: xcrun simctl io <udid> screenshot /path/to/file.png"
//   3. Call MCP tool `immersive_testing_capture_screen` (or run that xcrun command directly)
//   4. The test sees the PNG appear and returns. Read the PNG path to see the result.

@MainActor
final class RenderHarnessTests: XCTestCase {

    func testDemoScene() async throws {
        let url = try await RenderHarness.showForCapture(name: "demo-scene", holdSeconds: 15) {
            RealityView { content in
                content.add(SceneBuilder.makeDemo())
            }
        }
        let attachment = XCTAttachment(contentsOfFile: url)
        attachment.lifetime = XCTAttachment.Lifetime.keepAlways
        add(attachment)
    }

    func testColoredSpheres() async throws {
        let url = try await RenderHarness.showForCapture(
            name: "colored-spheres",
            options: RenderHarness.Options(settleSeconds: 1.5),
            holdSeconds: 15
        ) {
            RealityView { content in
                content.add(SceneBuilder.makeColoredSpheres())
            }
        }
        let attachment = XCTAttachment(contentsOfFile: url)
        attachment.lifetime = XCTAttachment.Lifetime.keepAlways
        add(attachment)
    }

    func testSingleEntity() async throws {
        let url = try await RenderHarness.showForCapture(name: "single-sphere", holdSeconds: 15) {
            RealityView { content in
                let sphere = ModelEntity(
                    mesh: .generateSphere(radius: 0.15),
                    materials: [SimpleMaterial(color: .systemPurple, isMetallic: true)]
                )
                sphere.position = [0, 0, -0.5]
                content.add(sphere)
            }
        }
        let attachment = XCTAttachment(contentsOfFile: url)
        attachment.lifetime = XCTAttachment.Lifetime.keepAlways
        add(attachment)
    }
}
