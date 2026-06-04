import XCTest
import RealityKit
import simd
@testable import ImmersiveTesting

// MARK: - MotionPath unit tests

@MainActor
final class MotionPathTests: XCTestCase {

    // MARK: linear factory

    func testLinearInterpolatesPosition() {
        let path = MotionPath.linear(from: [0, 0, 0], to: [10, 0, 0], duration: 2.0)
        let (mid, _) = path.pose(at: 1.0)
        XCTAssertEqual(mid.x, 5, accuracy: 1e-4)
        XCTAssertEqual(mid.y, 0, accuracy: 1e-4)
        XCTAssertEqual(mid.z, 0, accuracy: 1e-4)
    }

    func testLinearClampsBeforeStart() {
        let path = MotionPath.linear(from: [3, 0, 0], to: [10, 0, 0], duration: 2.0)
        let (pos, _) = path.pose(at: -5)
        XCTAssertEqual(pos.x, 3, accuracy: 1e-4)
    }

    func testLinearClampsAfterEnd() {
        let path = MotionPath.linear(from: [0, 0, 0], to: [7, 0, 0], duration: 1.0)
        let (pos, _) = path.pose(at: 99)
        XCTAssertEqual(pos.x, 7, accuracy: 1e-4)
    }

    func testLinearTotalDistance() {
        let path = MotionPath.linear(from: [0, 0, 0], to: [3, 4, 0], duration: 1.0)
        XCTAssertEqual(path.totalDistance, 5, accuracy: 1e-4)  // Pythagorean triple
    }

    func testLinearDuration() {
        let path = MotionPath.linear(from: .zero, to: [1, 0, 0], duration: 3.5)
        XCTAssertEqual(path.duration, 3.5, accuracy: 1e-6)
    }

    func testLinearMaxSpeed() {
        let path = MotionPath.linear(from: .zero, to: [9, 0, 0], duration: 3.0)
        XCTAssertEqual(path.maxSpeed, 3.0, accuracy: 1e-4)
    }

    func testLinearAverageSpeed() {
        let path = MotionPath.linear(from: .zero, to: [10, 0, 0], duration: 2.0)
        XCTAssertEqual(path.averageSpeed, 5.0, accuracy: 1e-4)
    }

    // MARK: arc / circle factory

    func testCircleReturnsToStart() {
        let path = MotionPath.circle(center: .zero, radius: 5, duration: 4.0)
        let (start, _) = path.pose(at: 0)
        let (end, _) = path.pose(at: 4.0)
        XCTAssertEqual(start.x, end.x, accuracy: 0.02)
        XCTAssertEqual(start.z, end.z, accuracy: 0.02)
    }

    func testArcPointsStayOnRadius() {
        let path = MotionPath.circle(center: [2, 0, 2], radius: 4, duration: 4.0, segments: 32)
        for kf in path.keyframes {
            let xzDist = length(SIMD2<Float>(kf.position.x - 2, kf.position.z - 2))
            XCTAssertEqual(xzDist, 4, accuracy: 0.01)
        }
    }

    func testArcConstantHeight() {
        let path = MotionPath.arc(center: .zero, radius: 3, startAngle: 0, endAngle: .pi,
                                  height: 2.0, duration: 1.0)
        for kf in path.keyframes {
            XCTAssertEqual(kf.position.y, 2.0, accuracy: 1e-4)
        }
    }

    // MARK: waypoints factory

    func testWaypointsDistributesTimeEvenly() {
        let pts: [SIMD3<Float>] = [[0,0,0],[1,0,0],[2,0,0],[3,0,0]]
        let path = MotionPath.waypoints(pts, duration: 3.0)
        XCTAssertEqual(path.keyframes.count, 4)
        XCTAssertEqual(path.keyframes[1].time, 1.0, accuracy: 1e-5)
        XCTAssertEqual(path.keyframes[2].time, 2.0, accuracy: 1e-5)
        XCTAssertEqual(path.keyframes[3].time, 3.0, accuracy: 1e-5)
    }

    func testWaypointsSinglePointZeroDuration() {
        let path = MotionPath.waypoints([[5, 0, 0]], duration: 2.0)
        XCTAssertEqual(path.keyframes.count, 1)
    }

    // MARK: transform

    func testTransformTranslation() {
        let path = MotionPath.linear(from: [0, 0, 0], to: [4, 0, 0], duration: 4.0)
        let tf = path.transform(at: 2.0)
        XCTAssertEqual(tf.translation.x, 2.0, accuracy: 1e-4)
    }

    // MARK: empty / single-keyframe edge cases

    func testEmptyPathReturnsZero() {
        let path = MotionPath(keyframes: [])
        let (pos, _) = path.pose(at: 0)
        XCTAssertEqual(pos, .zero)
        XCTAssertEqual(path.duration, 0)
        XCTAssertEqual(path.totalDistance, 0)
    }

    func testSingleKeyframeAlwaysReturnsThatPosition() {
        let path = MotionPath(keyframes: [PathKeyframe(time: 2, position: [7, 0, 0])])
        for t: Float in [0, 1, 2, 3, 100] {
            let (pos, _) = path.pose(at: t)
            XCTAssertEqual(pos.x, 7, accuracy: 1e-4)
        }
    }
}

// MARK: - PathBuilder DSL tests

@MainActor
final class PathBuilderTests: XCTestCase {

    func testMoveProducesLinearInterpolation() {
        let path = MotionPath(from: [0, 0, 0]) {
            PathSegment.move(to: [6, 0, 0], duration: 2.0)
        }
        let (mid, _) = path.pose(at: 1.0)
        XCTAssertEqual(mid.x, 3, accuracy: 0.01)
    }

    func testChainedMovesHaveCorrectDuration() {
        let path = MotionPath(from: [0, 0, 0]) {
            PathSegment.move(to: [4, 0, 0], duration: 2.0)
            PathSegment.move(to: [4, 0, 4], duration: 2.0)
        }
        XCTAssertEqual(path.duration, 4.0, accuracy: 1e-5)
    }

    func testChainedMovesEndAtCorrectPosition() {
        let path = MotionPath(from: [0, 0, 0]) {
            PathSegment.move(to: [4, 0, 0], duration: 2.0)
            PathSegment.move(to: [4, 0, 7], duration: 2.0)
        }
        let (end, _) = path.pose(at: 4.0)
        XCTAssertEqual(end.x, 4, accuracy: 0.01)
        XCTAssertEqual(end.z, 7, accuracy: 0.01)
    }

    func testPauseHoldsCurrentPosition() {
        let path = MotionPath(from: [3, 0, 5]) {
            PathSegment.pause(duration: 2.0)
        }
        for t: Float in [0, 0.5, 1.0, 1.8, 2.0] {
            let (pos, _) = path.pose(at: t)
            XCTAssertEqual(pos.x, 3, accuracy: 1e-4, "x should be 3 at t=\(t)")
            XCTAssertEqual(pos.z, 5, accuracy: 1e-4, "z should be 5 at t=\(t)")
        }
    }

    func testArcInfersStartAngleFromCurrentPosition() {
        // Start on +X axis at radius 5 from origin, arc 90° to +Z axis.
        let path = MotionPath(from: [5, 0, 0]) {
            PathSegment.arc(center: [0, 0, 0], toAngle: .pi / 2, radius: 5, duration: 1.0)
        }
        let (end, _) = path.pose(at: 1.0)
        XCTAssertEqual(end.x, 0, accuracy: 0.12)
        XCTAssertEqual(end.z, 5, accuracy: 0.12)
    }

    func testArcHeightDeltaApplied() {
        let path = MotionPath(from: [5, 0, 0]) {
            PathSegment.arc(center: [0, 0, 0], toAngle: .pi / 2, radius: 5,
                            duration: 1.0, heightDelta: 3.0)
        }
        let (end, _) = path.pose(at: 1.0)
        XCTAssertEqual(end.y, 3.0, accuracy: 0.05)
    }

    func testQuadraticBezierCurvePullsTowardControlPoint() {
        // Control point above the straight line pulls the midpoint up.
        let path = MotionPath(from: [0, 0, 0]) {
            PathSegment.curve(via: [5, 6, 0], to: [10, 0, 0], duration: 2.0)
        }
        // At t=0.5 the bezier gives: 0.25*(0,0,0) + 0.5*(5,6,0) + 0.25*(10,0,0) = (5, 3, 0)
        let (mid, _) = path.pose(at: 1.0)
        XCTAssertGreaterThan(mid.y, 2.0, "curve should be pulled upward by control point")
        XCTAssertEqual(mid.x, 5, accuracy: 0.2)
    }

    func testBezierEndsAtDestination() {
        let path = MotionPath(from: [0, 0, 0]) {
            PathSegment.curve(via: [5, 10, 0], to: [8, 0, 3], duration: 2.0)
        }
        let (end, _) = path.pose(at: 2.0)
        XCTAssertEqual(end.x, 8, accuracy: 0.05)
        XCTAssertEqual(end.z, 3, accuracy: 0.05)
    }

    func testComplexPathTotalDuration() {
        let path = MotionPath(from: .zero) {
            PathSegment.move(to: [1, 0, 0], duration: 1.0)
            PathSegment.pause(duration: 0.5)
            PathSegment.arc(center: [1, 0, 1], toAngle: .pi / 2, radius: 1, duration: 1.5)
            PathSegment.move(to: [0, 0, 0], duration: 1.0)
        }
        XCTAssertEqual(path.duration, 4.0, accuracy: 1e-4)
    }

    func testOptionalSegmentWithTrue() {
        let include = true
        let path = MotionPath(from: .zero) {
            if include {
                PathSegment.move(to: [5, 0, 0], duration: 1.0)
            }
        }
        XCTAssertEqual(path.duration, 1.0, accuracy: 1e-5)
    }

    func testOptionalSegmentWithFalse() {
        let include = false
        let path = MotionPath(from: .zero) {
            if include {
                PathSegment.move(to: [5, 0, 0], duration: 1.0)
            }
        }
        XCTAssertEqual(path.duration, 0, accuracy: 1e-5)
    }
}

// MARK: - PathRecorder tests

@MainActor
final class PathRecorderTests: XCTestCase {

    func testRecorderCapturesOneSamplePerTick() {
        let entity = Entity("mover")
        let clock = FrameClock(deltaTime: 1.0 / 90)
        let recorder = PathRecorder(entity: entity, clock: clock)
        let harness = SystemHarness(scene: TestScene { entity }, clock: clock)
        harness.register(recorder.asStep())
        harness.tick(frames: 45)
        XCTAssertEqual(recorder.samples.count, 45)
    }

    func testRecorderProducesCorrectTimestamps() {
        let entity = Entity("e")
        let clock = FrameClock(deltaTime: 1.0)  // 1 Hz for readable times
        let recorder = PathRecorder(entity: entity, clock: clock)
        entity.position = [0, 0, 0]; recorder.record()
        clock.tick()
        entity.position = [1, 0, 0]; recorder.record()
        clock.tick()
        entity.position = [2, 0, 0]; recorder.record()

        XCTAssertEqual(recorder.samples[0].time, 0, accuracy: 1e-5)
        XCTAssertEqual(recorder.samples[1].time, 1, accuracy: 1e-5)
        XCTAssertEqual(recorder.samples[2].time, 2, accuracy: 1e-5)
    }

    func testRecorderTotalDistance() {
        let entity = Entity("dist")
        let clock = FrameClock(deltaTime: 1.0)
        let recorder = PathRecorder(entity: entity, clock: clock)
        entity.position = [0, 0, 0]; recorder.record()
        clock.tick()
        entity.position = [3, 4, 0]; recorder.record()

        XCTAssertEqual(recorder.recordedPath.totalDistance, 5, accuracy: 1e-4)
    }

    func testRecorderResetClearsSamples() {
        let entity = Entity("r")
        let clock = FrameClock()
        let recorder = PathRecorder(entity: entity, clock: clock)
        recorder.record(); recorder.record()
        recorder.reset()
        XCTAssertTrue(recorder.samples.isEmpty)
    }

    func testRecordedPathInterpolatesCorrectly() {
        let entity = Entity("interp")
        let clock = FrameClock(deltaTime: 1.0)
        let recorder = PathRecorder(entity: entity, clock: clock)

        entity.position = [0, 0, 0]; recorder.record()
        clock.tick()
        entity.position = [10, 0, 0]; recorder.record()

        let path = recorder.recordedPath
        let (mid, _) = path.pose(at: 0.5)
        XCTAssertEqual(mid.x, 5, accuracy: 0.01)
    }
}

// MARK: - PathDrivenWorldTracking tests

@MainActor
final class PathDrivenWorldTrackingTests: XCTestCase {

    func testFollowsLinearPathOverTime() {
        let path = MotionPath.linear(from: [0, 0, 0], to: [9, 0, 0], duration: 3.0)
        let clock = FrameClock(deltaTime: 1.0)
        let tracking = PathDrivenWorldTracking(path: path, clock: clock)

        XCTAssertEqual(tracking.devicePosition().x, 0, accuracy: 1e-4)
        clock.tick()  // t=1
        XCTAssertEqual(tracking.devicePosition().x, 3, accuracy: 0.01)
        clock.tick()  // t=2
        XCTAssertEqual(tracking.devicePosition().x, 6, accuracy: 0.01)
        clock.tick()  // t=3
        XCTAssertEqual(tracking.devicePosition().x, 9, accuracy: 0.01)
    }

    func testClampsAtPathEnd() {
        let path = MotionPath.linear(from: .zero, to: [5, 0, 0], duration: 1.0)
        let clock = FrameClock(deltaTime: 1.0)
        let tracking = PathDrivenWorldTracking(path: path, clock: clock)
        clock.advance(frames: 10)  // well past end
        XCTAssertEqual(tracking.devicePosition().x, 5, accuracy: 0.01)
    }

    func testIntegratesWithHarnessChaseStep() {
        let playerPath = MotionPath.linear(from: [0, 1.6, 0], to: [10, 1.6, 0], duration: 5.0)
        let clock = FrameClock(deltaTime: 1.0 / 90)
        let worldTracking = PathDrivenWorldTracking(path: playerPath, clock: clock)
        let env = CompositeSceneEnvironment(worldTracking: worldTracking)

        let zombie = Entity("zombie")
        zombie.position = [0, 0, 0]
        let scene = TestScene { zombie }
        let harness = SystemHarness(scene: scene, clock: clock, environment: env)

        harness.registerStep("chase") { entities, dt, env in
            let target = env.worldTracking.devicePosition()
            for e in entities where e.name == "zombie" {
                let dir = target - e.position
                guard length(dir) > 0.01 else { continue }
                e.position += normalize(dir) * 2.0 * dt  // 2 m/s zombie
            }
        }

        harness.tick(frames: 90 * 5)  // 5 seconds
        XCTAssertGreaterThan(zombie.position.x, 5.0, "zombie should have chased the moving device")
    }
}

// MARK: - PathDrivenHands tests

@MainActor
final class PathDrivenHandsTests: XCTestCase {

    func testGunTipFollowsPath() {
        let path = MotionPath.linear(from: [0, 1.5, -3], to: [1, 1.5, -3], duration: 2.0)
        let clock = FrameClock(deltaTime: 1.0)
        let hands = PathDrivenHands(gunPath: path, clock: clock)

        XCTAssertEqual(hands.gunTipTransform().translation.x, 0, accuracy: 1e-4)
        clock.tick()
        XCTAssertEqual(hands.gunTipTransform().translation.x, 0.5, accuracy: 0.01)
        clock.tick()
        XCTAssertEqual(hands.gunTipTransform().translation.x, 1.0, accuracy: 0.01)
    }

    func testPinchDistancesAreFixed() {
        let path = MotionPath.linear(from: .zero, to: [1, 0, 0], duration: 1.0)
        let clock = FrameClock()
        let hands = PathDrivenHands(gunPath: path, clock: clock,
                                    rightPinchDistance: 0.04, leftPinchDistance: 0.5)
        XCTAssertTrue(hands.isRightPinching())
        XCTAssertFalse(hands.isLeftPinching())
    }
}

// MARK: - EntityPathDriver tests

@MainActor
final class EntityPathDriverTests: XCTestCase {

    func testDriverMovesEntityAlongLinearPath() {
        let entity = Entity("driven")
        entity.position = [0, 0, 0]
        let path = MotionPath.linear(from: [0, 0, 0], to: [10, 0, 0], duration: 2.0)
        let clock = FrameClock(deltaTime: 1.0 / 90)
        let driver = EntityPathDriver(entity: entity, path: path, clock: clock)
        let harness = SystemHarness(scene: TestScene { entity }, clock: clock)
        harness.register(driver.asStep())

        harness.tick(frames: 90)  // 1s → midpoint
        XCTAssertEqual(entity.position.x, 5, accuracy: 0.1)
    }

    func testDriverClampsAtPathEnd() {
        let entity = Entity("clamped")
        let path = MotionPath.linear(from: [0, 0, 0], to: [3, 0, 0], duration: 1.0)
        let clock = FrameClock(deltaTime: 1.0 / 90)
        let driver = EntityPathDriver(entity: entity, path: path, clock: clock)
        let harness = SystemHarness(scene: TestScene { entity }, clock: clock)
        harness.register(driver.asStep())

        harness.tick(frames: 270)  // 3s — far past path end
        XCTAssertEqual(entity.position.x, 3, accuracy: 0.01)
    }

    func testDriverFollowsComplexDSLPath() {
        let entity = Entity("complex")
        entity.position = [0, 0, 0]
        let path = MotionPath(from: [0, 0, 0]) {
            PathSegment.move(to: [5, 0, 0], duration: 1.0)
            PathSegment.pause(duration: 0.5)
            PathSegment.move(to: [5, 0, 5], duration: 1.0)
        }
        let clock = FrameClock(deltaTime: 1.0 / 90)
        let driver = EntityPathDriver(entity: entity, path: path, clock: clock)
        let harness = SystemHarness(scene: TestScene { entity }, clock: clock)
        harness.register(driver.asStep())

        // After 1.0s — should be at [5, 0, 0]
        harness.tick(frames: 90)
        XCTAssertEqual(entity.position.x, 5, accuracy: 0.1)

        // After 1.5s — still at [5, 0, 0] (pause)
        harness.tick(frames: 45)
        XCTAssertEqual(entity.position.x, 5, accuracy: 0.1)
        XCTAssertEqual(entity.position.z, 0, accuracy: 0.1)

        // After 2.5s — should be at [5, 0, 5]
        harness.tick(frames: 90)
        XCTAssertEqual(entity.position.z, 5, accuracy: 0.1)
    }
}

// MARK: - SpatialRegion tests

@MainActor
final class SpatialRegionTests: XCTestCase {

    func testSphereContainsInteriorPoint() {
        let r = SpatialRegion.sphere(center: .zero, radius: 5)
        XCTAssertTrue(r.contains([3, 0, 0]))
        XCTAssertTrue(r.contains([0, 4, 0]))
        XCTAssertTrue(r.contains([0, 0, 4.9]))
    }

    func testSphereContainsBoundaryPoint() {
        let r = SpatialRegion.sphere(center: .zero, radius: 3)
        XCTAssertTrue(r.contains([3, 0, 0]))   // exactly on surface
    }

    func testSphereExcludesExteriorPoint() {
        let r = SpatialRegion.sphere(center: .zero, radius: 5)
        XCTAssertFalse(r.contains([6, 0, 0]))
        XCTAssertFalse(r.contains([4, 4, 0]))  // sqrt(32) > 5
    }

    func testSphereOffCenter() {
        let r = SpatialRegion.sphere(center: [10, 5, 0], radius: 2)
        XCTAssertTrue(r.contains([10, 5, 0]))   // center
        XCTAssertTrue(r.contains([11, 5, 0]))   // 1m away
        XCTAssertFalse(r.contains([13, 5, 0]))  // 3m away
    }

    func testBoxContainsInterior() {
        let r = SpatialRegion.box(center: .zero, size: [4, 2, 4])
        XCTAssertTrue(r.contains([1.9, 0.9, 1.9]))
        XCTAssertFalse(r.contains([2.1, 0, 0]))
    }

    func testBoxBoundary() {
        let r = SpatialRegion.box(center: .zero, size: [6, 4, 6])
        XCTAssertTrue(r.contains([3, 0, 0]))   // on face
        XCTAssertFalse(r.contains([3.01, 0, 0]))
    }

    func testCylinderContainsInterior() {
        let r = SpatialRegion.cylinder(center: .zero, radius: 3, halfHeight: 5)
        XCTAssertTrue(r.contains([2, 4, 0]))
        XCTAssertTrue(r.contains([0, -4.9, 0]))
    }

    func testCylinderExcludesOutsideRadius() {
        let r = SpatialRegion.cylinder(center: .zero, radius: 3, halfHeight: 5)
        XCTAssertFalse(r.contains([4, 0, 0]))
    }

    func testCylinderExcludesOutsideHeight() {
        let r = SpatialRegion.cylinder(center: .zero, radius: 3, halfHeight: 2)
        XCTAssertFalse(r.contains([0, 3, 0]))
    }

    func testInfiniteHeightCylinder() {
        let r = SpatialRegion.cylinder(center: .zero, radius: 3, halfHeight: .infinity)
        XCTAssertTrue(r.contains([0, 10000, 0]))
        XCTAssertTrue(r.contains([0, -9999, 0]))
        XCTAssertFalse(r.contains([4, 0, 0]))
    }

    func testContainsAll() {
        let r = SpatialRegion.sphere(center: .zero, radius: 10)
        XCTAssertTrue(r.containsAll([[1,0,0], [0,1,0], [-3,0,4]]))
        XCTAssertFalse(r.containsAll([[1,0,0], [15,0,0]]))
    }

    func testViolations() {
        let r = SpatialRegion.sphere(center: .zero, radius: 5)
        let pts: [SIMD3<Float>] = [[1,0,0], [8,0,0], [2,2,0], [9,0,0]]
        let v = r.violations(in: pts)
        XCTAssertEqual(v.count, 2)
    }
}

// MARK: - MotionAssertions tests

@MainActor
final class MotionAssertionPassTests: XCTestCase {

    private func buildRecorder(
        _ pairs: [(t: Float, pos: SIMD3<Float>)]
    ) -> PathRecorder {
        let entity = Entity("assert-subject")
        let clock = FrameClock(deltaTime: 1.0)
        let recorder = PathRecorder(entity: entity, clock: clock)
        for (t, pos) in pairs {
            entity.position = pos
            // Manually drive the clock to desired time then record
            while Float(clock.time) < t { clock.tick() }
            recorder.record()
        }
        return recorder
    }

    func testMaxSpeedPassesForSlowMovement() {
        let entity = Entity("slow")
        let clock = FrameClock(deltaTime: 1.0)
        let recorder = PathRecorder(entity: entity, clock: clock)

        entity.position = [0, 0, 0]; recorder.record()
        clock.tick()
        entity.position = [1, 0, 0]; recorder.record()
        clock.tick()
        entity.position = [2, 0, 0]; recorder.record()

        // 1 m/s — should pass a 2 m/s limit
        XCTAssertMaxSpeed(recorder, lessThan: 2.0)
    }

    func testReachesPositionPassWhenClose() {
        let entity = Entity("e")
        let clock = FrameClock(deltaTime: 1.0)
        let recorder = PathRecorder(entity: entity, clock: clock)
        entity.position = [0, 0, 0]; recorder.record()
        clock.tick()
        entity.position = [5, 0, 0]; recorder.record()

        XCTAssertReachesPosition(recorder, position: [5.05, 0, 0], within: 0.1)
    }

    func testPathLengthApprox() {
        let entity = Entity("len")
        let clock = FrameClock(deltaTime: 1.0)
        let recorder = PathRecorder(entity: entity, clock: clock)
        entity.position = [0, 0, 0]; recorder.record()
        clock.tick()
        entity.position = [3, 4, 0]; recorder.record()  // length 5

        XCTAssertPathLength(recorder, approximately: 5.0, within: 0.01)
    }

    func testEntityWithinSpherePass() {
        let entity = Entity("e")
        entity.position = [2, 0, 0]
        let region = SpatialRegion.sphere(center: .zero, radius: 5)
        XCTAssertEntity(entity, within: region)
    }

    func testSmoothMotionPassesForConstantSpeed() {
        let entity = Entity("steady")
        let clock = FrameClock(deltaTime: 1.0)
        let recorder = PathRecorder(entity: entity, clock: clock)
        // Constant 1 m/s — delta-v per frame is 0
        for i in 0...5 {
            entity.position = [Float(i), 0, 0]
            recorder.record()
            if i < 5 { clock.tick() }
        }
        XCTAssertSmoothMotion(recorder, maxSpeedChangePerFrame: 0.01)
    }

    func testFollowsPathWithinTolerance() {
        let entity = Entity("follower")
        let clock = FrameClock(deltaTime: 1.0)
        let recorder = PathRecorder(entity: entity, clock: clock)

        // Entity follows a slightly-noisy linear path.
        entity.position = [0.02, 0, 0]; recorder.record()  // t=0, slightly off [0,0,0]
        clock.tick()
        entity.position = [4.98, 0, 0]; recorder.record()  // t=1, slightly off [5,0,0]

        let expected = MotionPath.linear(from: .zero, to: [5, 0, 0], duration: 1.0)
        XCTAssertFollowsPath(recorder, matches: expected, within: 0.05)
    }
}

// MARK: - Canned SceneInvariant tests

private struct BallTag: Component {}

@MainActor
final class CannedInvariantTests: XCTestCase {

    func testWithinRegionInvariantPasses() {
        let root = Entity("r")
        let a = Entity("a"); a.position = [1, 0, 0]; a.components.set(BallTag())
        let b = Entity("b"); b.position = [2, 0, 0]; b.components.set(BallTag())
        root.addChild(a); root.addChild(b)

        let region = SpatialRegion.sphere(center: .zero, radius: 5)
        let inv = SceneInvariant.withinRegion("balls in sphere", region: region) { r in
            r.entities(with: BallTag.self)
        }
        XCTAssertTrue(inv.check(root))
    }

    func testWithinRegionInvariantFails() {
        let root = Entity("r")
        let a = Entity("a"); a.position = [20, 0, 0]; a.components.set(BallTag())
        root.addChild(a)

        let region = SpatialRegion.sphere(center: .zero, radius: 5)
        let inv = SceneInvariant.withinRegion("balls in sphere", region: region) { r in
            r.entities(with: BallTag.self)
        }
        XCTAssertFalse(inv.check(root))
    }

    func testAboveFloorInvariantPasses() {
        let root = Entity("r")
        let e = Entity("e"); e.position = [0, 0.5, 0]
        root.addChild(e)
        XCTAssertTrue(SceneInvariant.aboveFloor().check(root))
    }

    func testAboveFloorInvariantFails() {
        let root = Entity("r")
        let e = Entity("e"); e.position = [0, -1, 0]
        root.addChild(e)
        XCTAssertFalse(SceneInvariant.aboveFloor().check(root))
    }

    func testComponentStaysWithinInvariant() {
        let root = Entity("r")
        let inside = Entity("inside"); inside.position = [1, 0, 0]; inside.components.set(BallTag())
        root.addChild(inside)

        let region = SpatialRegion.box(center: .zero, size: [5, 5, 5])
        let inv = SceneInvariant.component(BallTag.self, staysWithin: region)
        XCTAssertTrue(inv.check(root))
    }
}

// MARK: - End-to-end integration tests

@MainActor
final class MotionIntegrationTests: XCTestCase {

    /// Classic game test: zombie chases a player who walks a scripted path.
    func testZombieChasesPathDrivenDevice() {
        let playerPath = MotionPath.linear(from: [0, 1.6, 0], to: [10, 1.6, 0], duration: 5.0)
        let clock = FrameClock(deltaTime: 1.0 / 90)
        let worldTracking = PathDrivenWorldTracking(path: playerPath, clock: clock)
        let env = CompositeSceneEnvironment(worldTracking: worldTracking)

        let zombie = Entity("zombie")
        zombie.position = [0, 0, 0]
        let scene = TestScene { zombie }
        let recorder = PathRecorder(entity: zombie, clock: clock)
        let harness = SystemHarness(scene: scene, clock: clock, environment: env)

        harness.registerStep("chase") { entities, dt, env in
            let target = env.worldTracking.devicePosition()
            for e in entities where e.name == "zombie" {
                let dir = target - e.position
                guard length(dir) > 0.05 else { continue }
                e.position += normalize(dir) * 2.0 * dt
            }
        }
        harness.register(recorder.asStep())

        let arena = SpatialRegion.box(center: [5, 0, 0], size: [15, 5, 15], name: "arena")
        harness.tick(frames: 90 * 5, invariants: SceneInvariantSet {
            SceneInvariant.noNaNTransforms
            SceneInvariant.aboveFloor(minY: -0.5)
        })

        // Zombie should have moved meaningfully toward player.
        XCTAssertGreaterThan(zombie.position.x, 5.0)
        XCTAssertMaxSpeed(recorder, lessThan: 3.0)       // no teleports
        XCTAssertEntity(zombie, within: arena)            // stayed in bounds
    }

    /// Patrol-route test: entity follows a looping waypoint path via EntityPathDriver.
    func testEntityDriverFollowsWaypointRoute() {
        let waypoints: [SIMD3<Float>] = [[0,0,0],[4,0,0],[4,0,4],[0,0,4]]
        let route = MotionPath.waypoints(waypoints, duration: 4.0)

        let entity = Entity("patroller")
        let clock = FrameClock(deltaTime: 1.0 / 90)
        let driver = EntityPathDriver(entity: entity, path: route, clock: clock)
        let recorder = PathRecorder(entity: entity, clock: clock)
        let harness = SystemHarness(scene: TestScene { entity }, clock: clock)

        harness.register(driver.asStep())
        harness.register(recorder.asStep())
        harness.tick(frames: 360)  // 4 seconds

        // Entity should have ended near the last waypoint.
        XCTAssertReachesPosition(recorder, position: [4, 0, 4], within: 0.2)
        // And never left the patrol square.
        let zone = SpatialRegion.box(center: [2, 0, 2], size: [6, 2, 6], name: "patrol zone")
        XCTAssertEntity(entity, within: zone)
    }

    /// Aiming test: gun tip sweeps an arc path, bullets update to match.
    func testBulletFollowsPathDrivenGunTip() {
        let sweep = MotionPath.arc(
            center: [0, 1.5, -3], radius: 1.0,
            startAngle: -.pi / 4, endAngle: .pi / 4,
            height: 1.5, duration: 2.0
        )
        let clock = FrameClock(deltaTime: 1.0 / 90)
        let hands = PathDrivenHands(gunPath: sweep, clock: clock, rightPinchDistance: 0.04)
        let env = CompositeSceneEnvironment(hands: hands)

        let bullet = Entity("bullet")
        let scene = TestScene { bullet }
        let recorder = PathRecorder(entity: bullet, clock: clock)
        let harness = SystemHarness(scene: scene, clock: clock, environment: env)

        harness.registerStep("track-tip") { entities, dt, env in
            let tip = env.hands.gunTipTransform()
            for e in entities where e.name == "bullet" {
                e.position = tip.translation
            }
        }
        harness.register(recorder.asStep())
        harness.tick(frames: 180)

        // Bullet should have swept meaningfully across the arc.
        XCTAssertGreaterThan(recorder.recordedPath.totalDistance, 0.1)
        XCTAssertMaxSpeed(recorder, lessThan: 5.0)
    }
}
