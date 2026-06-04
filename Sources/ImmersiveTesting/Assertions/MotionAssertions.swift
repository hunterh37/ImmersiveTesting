import XCTest
import RealityKit
import simd
import ImmersiveTestingRuntime

// MARK: - Path-level assertions

/// Asserts that a `PathRecorder`'s trajectory matches `expected` at each of `expected`'s
/// keyframe times (within `tolerance` metres per keyframe).
///
/// For each keyframe in `expected`, the recorder's interpolated position at that time must
/// lie within `tolerance` metres. This is the primary assertion for "entity followed the
/// scripted route."
///
/// ```swift
/// let route = MotionPath.waypoints([[0,0,0],[5,0,0],[5,0,5]], duration: 3.0)
/// XCTAssertFollowsPath(recorder, matches: route, within: 0.15)
/// ```
@MainActor
public func XCTAssertFollowsPath(
    _ recorder: PathRecorder,
    matches expected: MotionPath,
    within tolerance: Float = 0.05,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    let actual = recorder.recordedPath
    for kf in expected.keyframes {
        let (actualPos, _) = actual.pose(at: kf.time)
        let dist = distance(actualPos, kf.position)
        if dist > tolerance {
            XCTFail(
                "Path deviated \(fmt(dist))m at t=\(fmt(kf.time))s " +
                "(expected \(vec(kf.position)), got \(vec(actualPos)), tolerance \(fmt(tolerance))m)",
                file: file, line: line
            )
        }
    }
}

/// Asserts that the cumulative arc length of the recorded path is within `tolerance`
/// metres of `expected`. Use this to verify total distance travelled without caring
/// about the exact route taken.
///
/// ```swift
/// XCTAssertPathLength(recorder, approximately: 10.0, within: 0.5)
/// ```
@MainActor
public func XCTAssertPathLength(
    _ recorder: PathRecorder,
    approximately expected: Float,
    within tolerance: Float,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    let actual = recorder.recordedPath.totalDistance
    let error = abs(actual - expected)
    if error > tolerance {
        XCTFail(
            "Path length \(fmt(actual))m ≠ expected \(fmt(expected))m (error \(fmt(error))m, tolerance \(fmt(tolerance))m)",
            file: file, line: line
        )
    }
}

// MARK: - Speed assertions

/// Asserts that no two consecutive samples in the recording represent a speed above
/// `maxSpeed` metres per second.
///
/// A spike above the limit typically indicates a teleport (buggy position reset), a
/// skipped frame, or an AI system producing an illegal move. The assertion fails on the
/// **first** violation and reports the exact time and positions involved.
///
/// ```swift
/// XCTAssertMaxSpeed(recorder, lessThan: 5.0)   // no teleporting
/// ```
@MainActor
public func XCTAssertMaxSpeed(
    _ recorder: PathRecorder,
    lessThan maxSpeed: Float,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    let samples = recorder.samples
    guard samples.count > 1 else { return }
    for (a, b) in zip(samples, samples.dropFirst()) {
        let dt = b.time - a.time
        guard dt > 0 else { continue }
        let speed = distance(a.position, b.position) / dt
        if speed > maxSpeed {
            XCTFail(
                "Speed spike \(fmt(speed)) m/s at t=\(fmt(b.time))s exceeds \(fmt(maxSpeed)) m/s " +
                "(\(vec(a.position)) → \(vec(b.position)))",
                file: file, line: line
            )
            return
        }
    }
}

/// Asserts that no frame-to-frame speed change (delta-v) exceeds `maxSpeedChangePerFrame`
/// metres per second. Use this to verify smoothly damped or interpolated motion — abrupt
/// changes indicate missing easing, overshooting PID, or sudden target teleports.
///
/// ```swift
/// XCTAssertSmoothMotion(recorder, maxSpeedChangePerFrame: 0.2)
/// ```
@MainActor
public func XCTAssertSmoothMotion(
    _ recorder: PathRecorder,
    maxSpeedChangePerFrame: Float,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    let samples = recorder.samples
    guard samples.count > 2 else { return }
    var prevSpeed: Float? = nil
    for (a, b) in zip(samples, samples.dropFirst()) {
        let dt = b.time - a.time
        guard dt > 0 else { continue }
        let speed = distance(a.position, b.position) / dt
        if let prev = prevSpeed {
            let delta = abs(speed - prev)
            if delta > maxSpeedChangePerFrame {
                XCTFail(
                    "Abrupt speed change \(fmt(delta)) m/s/frame at t=\(fmt(b.time))s " +
                    "(limit: \(fmt(maxSpeedChangePerFrame)) m/s/frame)",
                    file: file, line: line
                )
                return
            }
        }
        prevSpeed = speed
    }
}

// MARK: - Positional assertions

/// Asserts that the entity's recorded trajectory passes within `tolerance` metres of
/// `target` at some point during the simulation.
///
/// ```swift
/// XCTAssertReachesPosition(recorder, position: objective.position, within: 0.5)
/// ```
@MainActor
public func XCTAssertReachesPosition(
    _ recorder: PathRecorder,
    position target: SIMD3<Float>,
    within tolerance: Float,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    let closest = recorder.samples.map { distance($0.position, target) }.min() ?? .infinity
    if closest > tolerance {
        XCTFail(
            "Entity never reached \(vec(target)) within \(fmt(tolerance))m " +
            "— closest approach: \(fmt(closest))m",
            file: file, line: line
        )
    }
}

// MARK: - Spatial-region assertions

/// Asserts that `entity`'s current world-space position lies within `region`.
///
/// ```swift
/// let arena = SpatialRegion.sphere(center: .zero, radius: 10, name: "arena")
/// XCTAssertEntity(zombie, within: arena)
/// ```
@MainActor
public func XCTAssertEntity(
    _ entity: Entity,
    within region: SpatialRegion,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    let pos = entity.position(relativeTo: nil)
    if !region.contains(pos) {
        XCTFail(
            "Entity '\(entity.name)' at \(vec(pos)) is outside region '\(region.name)'",
            file: file, line: line
        )
    }
}

/// Asserts that **all** entities carrying `componentType` in `root`'s subtree lie within `region`.
///
/// ```swift
/// let spawnZone = SpatialRegion.cylinder(center: .zero, radius: 8, name: "spawn zone")
/// XCTAssertAllEntities(ZombieComponent.self, in: scene.root, within: spawnZone)
/// ```
@MainActor
public func XCTAssertAllEntities<C: Component>(
    _ componentType: C.Type,
    in root: Entity,
    within region: SpatialRegion,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    for entity in root.entities(with: componentType) {
        XCTAssertEntity(entity, within: region, file: file, line: line)
    }
}

// MARK: - SceneInvariant extensions for motion / spatial

extension SceneInvariant {

    /// All entities returned by `filter` must stay within `region` every simulated frame.
    ///
    /// Pass this to `SceneInvariantSet` so it is checked automatically after each tick:
    ///
    /// ```swift
    /// let arena = SpatialRegion.sphere(center: .zero, radius: 10, name: "arena")
    /// let invariants = SceneInvariantSet {
    ///     SceneInvariant.withinRegion("zombies in arena", region: arena) { root in
    ///         root.entities(with: ZombieComponent.self)
    ///     }
    /// }
    /// harness.tick(frames: 300, invariants: invariants)
    /// ```
    @MainActor
    public static func withinRegion(
        _ name: String,
        region: SpatialRegion,
        entities filter: @MainActor @escaping (Entity) -> [Entity]
    ) -> SceneInvariant {
        SceneInvariant(name) { root in
            filter(root).allSatisfy { region.contains($0.position(relativeTo: nil)) }
        }
    }

    /// No entity in the subtree may have a Y position below `minY`.
    ///
    /// ```swift
    /// SceneInvariant.aboveFloor()   // default minY = 0
    /// SceneInvariant.aboveFloor(minY: -0.1)   // small tolerance for physics settling
    /// ```
    public static func aboveFloor(minY: Float = 0) -> SceneInvariant {
        SceneInvariant("all entities above y≥\(minY)") { root in
            root.allEntities.allSatisfy { $0.position(relativeTo: nil).y >= minY }
        }
    }

    /// Every entity carrying `componentType` must remain within `region` at all times.
    public static func component<C: Component>(
        _ type: C.Type,
        staysWithin region: SpatialRegion
    ) -> SceneInvariant {
        SceneInvariant("\(type) within '\(region.name)'") { root in
            root.entities(with: type).allSatisfy { region.contains($0.position(relativeTo: nil)) }
        }
    }
}

// MARK: - Private formatting helpers

private func fmt(_ v: Float) -> String { String(format: "%.4f", v) }
private func vec(_ v: SIMD3<Float>) -> String {
    "(\(String(format: "%.3f", v.x)), \(String(format: "%.3f", v.y)), \(String(format: "%.3f", v.z)))"
}
