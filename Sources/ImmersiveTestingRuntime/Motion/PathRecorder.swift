import RealityKit
import simd

// MARK: - PathRecorder

/// Records the world-space pose of a `RealityKit` entity on each simulation tick,
/// producing a `MotionPath` you can assert against after the simulation runs.
///
/// Attach as a `SystemStep` (ideally as the **last** step so all movement steps have
/// already run), then inspect `recordedPath`, `samples`, or use the motion assertions:
///
/// ```swift
/// let zombie = scene["zombie"]!
/// let recorder = PathRecorder(entity: zombie, clock: harness.clock)
/// harness.register(recorder.asStep())          // records after every tick
///
/// harness.tick(frames: 270)                    // 3 seconds at 90 Hz
///
/// XCTAssertReachesPosition(recorder, position: [0, 0, 8], within: 0.3)
/// XCTAssertMaxSpeed(recorder, lessThan: 5.0)   // no teleports
/// XCTAssertSmoothMotion(recorder, maxSpeedChangePerFrame: 0.3)
/// ```
///
/// > **Tip:** Register the recorder step last. Earlier steps mutate positions; the
/// > recorder captures the final state of each frame.
@MainActor
public final class PathRecorder {

    // MARK: - Sample

    /// A single captured pose.
    public struct Sample: Sendable {
        /// Simulated time at capture (seconds).
        public let time: Float
        /// World-space position at capture.
        public let position: SIMD3<Float>
        /// Local orientation at capture (`entity.orientation`).
        /// For entities with non-trivial parent hierarchies, use `transformMatrix(relativeTo: nil)`
        /// directly if world orientation is required.
        public let rotation: simd_quatf
    }

    // MARK: - Public state

    /// All captured samples in tick order.
    public private(set) var samples: [Sample] = []

    // MARK: - Private state

    private let entity: Entity
    private let clock: FrameClock

    // MARK: - Init

    /// - Parameters:
    ///   - entity: The entity whose pose to record each tick.
    ///   - clock: The same `FrameClock` the harness uses, so sample timestamps align
    ///     with the simulation timeline.
    public init(entity: Entity, clock: FrameClock) {
        self.entity = entity
        self.clock = clock
    }

    // MARK: - Recording

    /// Captures the entity's current pose. Called automatically by the step returned
    /// from `asStep()`, or call manually for fine-grained control.
    public func record() {
        samples.append(Sample(
            time: Float(clock.time),
            position: entity.position(relativeTo: nil),
            rotation: entity.orientation
        ))
    }

    /// Discards all recorded samples. The clock reference is untouched, so times in
    /// subsequent samples continue from wherever the clock is now.
    public func reset() { samples.removeAll() }

    // MARK: - Conversion

    /// The recorded samples as a `MotionPath`, ready for spatial assertions or comparison
    /// against a reference path built with `MotionPath.linear`, `@PathBuilder`, etc.
    public var recordedPath: MotionPath {
        MotionPath(keyframes: samples.map {
            PathKeyframe(time: $0.time, position: $0.position, rotation: $0.rotation)
        })
    }

    // MARK: - As a SystemStep

    /// A `SystemStep` that captures the entity's pose once per tick.
    ///
    /// Register it **after** all movement steps so the recorded position reflects the
    /// frame's final state:
    ///
    /// ```swift
    /// harness.registerStep("motion")  { … }
    /// harness.registerStep("chase")   { … }
    /// harness.register(recorder.asStep())   // last — sees the moved positions
    /// ```
    ///
    /// - Parameter name: Optional step name shown in test output. Defaults to
    ///   `"record(<entityName>)"`.
    public func asStep(name: String? = nil) -> SystemStep {
        let stepName = name ?? "record(\(entity.name))"
        return SystemStep(stepName) { [weak self] _, _ in
            self?.record()
        }
    }
}
