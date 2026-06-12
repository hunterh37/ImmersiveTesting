import XCTest
import RealityKit
import simd
@testable import ImmersiveTesting
@testable import ImmersiveTestingRuntime

@MainActor
final class RegressionTests: XCTestCase {

    // MARK: Issue #2 — SystemHarness snapshots entity list before steps run

    func test_issue2_spawnedEntityInvisibleToLaterStepsSameFrame() {
        let scene = TestScene(rootName: "root") {}
        let harness = SystemHarness(scene: scene)

        var stepBSawSpawned = false

        harness.registerStep("spawn") { entities, _ in
            // Step A spawns a child this frame.
            guard let root = entities.first else { return }
            let e = Entity(); e.name = "spawned"
            root.addChild(e)
        }
        harness.registerStep("observe") { entities, _ in
            // Step B (same frame) should see the spawned entity if the list were live.
            stepBSawSpawned = entities.contains { $0.name == "spawned" }
        }

        harness.tick()
        // FIXED: later step in the SAME frame now sees the spawn (live entity set per step).
        XCTAssertTrue(stepBSawSpawned, "spawned entity must be visible to later step in same frame")
    }

    // MARK: Issue #3 — SceneSnapshot.diff pairs duplicate-named siblings by first match

    func test_issue3_diffSilentlyMissesRemovalOfDuplicateNamedSibling() {
        // Baseline: TWO children both named "hitbox".
        let baselineRoot = Entity(); baselineRoot.name = "root"
        let a = Entity(); a.name = "hitbox"; a.position = [0, 0, 0]
        let b = Entity(); b.name = "hitbox"; b.position = [1, 0, 0]
        baselineRoot.addChild(a); baselineRoot.addChild(b)
        let baseline = SceneSnapshot(baselineRoot)

        // Current: ONE "hitbox" removed — a real structural change.
        let currentRoot = Entity(); currentRoot.name = "root"
        let c = Entity(); c.name = "hitbox"; c.position = [0, 0, 0]
        currentRoot.addChild(c)
        let current = SceneSnapshot(currentRoot)

        XCTAssertEqual(baseline.entityCount, 3)
        XCTAssertEqual(current.entityCount, 2) // genuinely different

        let diff = current.diff(from: baseline)
        // FIXED: removal of a duplicate-named sibling is now reported.
        XCTAssertNotNil(diff, "diff must detect removal of a duplicate-named sibling")
        XCTAssertTrue(diff?.contains("removed") ?? false, "diff should name the removed child")
    }

    // MARK: Issue #4 — PathRecorder records LOCAL rotation, WORLD position.
    // NOT fixed: PathRecorder.Sample documents rotation as local-by-design. This test pins
    // the documented behavior so it can't change silently — it is a known tradeoff, not a fix.

    func test_issue4_recorderRecordsLocalRotationNotWorld() {
        let parent = Entity(); parent.name = "parent"
        // Rotate parent 90° about Y.
        parent.orientation = simd_quatf(angle: .pi / 2, axis: [0, 1, 0])

        let child = Entity(); child.name = "child"
        child.orientation = simd_quatf(angle: 0, axis: [0, 1, 0]) // identity locally
        parent.addChild(child)

        let clock = FrameClock()
        let recorder = PathRecorder(entity: child, clock: clock)
        recorder.record()

        let recorded = recorder.samples[0].rotation
        let worldOrientation = child.orientation(relativeTo: nil)

        let recordedAngle = recorded.angle
        let worldAngle = worldOrientation.angle

        // World orientation is 90°, but recorder stored local (0°).
        XCTAssertEqual(recordedAngle, 0, accuracy: 1e-4, "recorder stored LOCAL rotation")
        XCTAssertEqual(worldAngle, .pi / 2, accuracy: 1e-4, "true WORLD rotation is 90°")
        // Position IS world though — proving the mismatch.
        let recordedPos = recorder.samples[0].position
        XCTAssertEqual(recordedPos, child.position(relativeTo: nil), "position is world-space")
    }

    // MARK: Issue #5 — EntityPathDriver writes a WORLD-space path pose into entity.position (LOCAL)

    func test_issue5_driverWritesWorldPoseIntoLocalPositionUnderParent() {
        // Parent is translated +10 on X. A child driven along a WORLD path to [5,0,0]
        // should END UP at world [5,0,0] — the doc says "world-space position".
        let parent = Entity(); parent.name = "parent"
        parent.position = [10, 0, 0]
        let child = Entity(); child.name = "child"
        parent.addChild(child)

        let clock = FrameClock()
        // Path holds at world [5,0,0] for the whole duration.
        let path = MotionPath.linear(from: [5, 0, 0], to: [5, 0, 0], duration: 1.0)
        let driver = EntityPathDriver(entity: child, path: path, clock: clock)
        let step = driver.asStep()

        step.body(ArraySlice([child]), clock.dt, CompositeSceneEnvironment())

        let world = child.position(relativeTo: nil)
        // FIXED: driver writes through world-relative setter, so child lands on the path
        // regardless of parent transform.
        XCTAssertEqual(world.x, 5, accuracy: 1e-4, "driver should place child at WORLD x=5")
    }
}
