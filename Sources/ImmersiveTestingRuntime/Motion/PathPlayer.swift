import RealityKit
import simd

// MARK: - PathDrivenWorldTracking

/// A `WorldTrackingProviding` implementation that drives the simulated device (head) pose
/// along a pre-built `MotionPath`, reading the current time from a shared `FrameClock`.
///
/// Inject this into `CompositeSceneEnvironment` so any harness step that reads
/// `env.worldTracking.devicePosition()` sees the device "walking" the scripted path
/// automatically — no manual mutation of `FakeWorldTracking.position` each frame.
///
/// ```swift
/// let path = MotionPath.linear(from: [0, 1.6, 0], to: [10, 1.6, 0], duration: 5.0)
/// let clock = FrameClock()
/// let worldTracking = PathDrivenWorldTracking(path: path, clock: clock)
/// let env = CompositeSceneEnvironment(worldTracking: worldTracking)
/// let harness = SystemHarness(scene: scene, clock: clock, environment: env)
///
/// harness.tick(frames: 450)   // 5 seconds — device walks the full 10 m path
/// ```
///
/// > **Clock sharing:** pass the **same** `FrameClock` instance to `SystemHarness` and
/// > `PathDrivenWorldTracking`. The harness advances the clock; the provider reads it.
/// > Never create two clocks for the same simulation.
@MainActor
public final class PathDrivenWorldTracking: WorldTrackingProviding {

    /// The spatial path the simulated device follows.
    public let path: MotionPath

    private let clock: FrameClock

    public init(path: MotionPath, clock: FrameClock) {
        self.path = path
        self.clock = clock
    }

    public func deviceTransform() -> Transform {
        path.transform(at: Float(clock.time))
    }
}

// MARK: - PathDrivenHands

/// A `HandTrackingProviding` implementation that drives the pointer-tip transform along a
/// `MotionPath` — useful for simulating a sweep or aim arc without having to update
/// `ScriptedHands.pointerTip` every tick.
///
/// Pinch distances remain fixed (open by default). Only the pointer tip follows the path.
///
/// ```swift
/// // Simulate a sweep left-to-right over 2 seconds.
/// let sweepPath = MotionPath.arc(
///     center: [0, 1.5, -3], radius: 1.0,
///     startAngle: -.pi / 4, endAngle: .pi / 4,
///     height: 1.5, duration: 2.0
/// )
/// let clock = FrameClock()
/// let hands = PathDrivenHands(pointerPath: sweepPath, clock: clock)
/// let env   = CompositeSceneEnvironment(hands: hands)
/// let harness = SystemHarness(scene: scene, clock: clock, environment: env)
/// ```
@MainActor
public final class PathDrivenHands: HandTrackingProviding {

    /// Thumb-to-index distance on the right hand. Defaults to open (1 m).
    public var rightPinchDistance: Float
    /// Thumb-to-index distance on the left hand. Defaults to open (1 m).
    public var leftPinchDistance: Float

    private let pointerPath: MotionPath
    private let clock: FrameClock

    /// - Parameters:
    ///   - pointerPath: The path the pointer tip follows over time.
    ///   - clock: Shared simulation clock — must be the same instance as the harness uses.
    ///   - rightPinchDistance: Starting right-hand pinch distance. Mutate to trigger interactions.
    ///   - leftPinchDistance: Starting left-hand pinch distance.
    public init(
        pointerPath: MotionPath,
        clock: FrameClock,
        rightPinchDistance: Float = 1.0,
        leftPinchDistance: Float = 1.0
    ) {
        self.pointerPath = pointerPath
        self.clock = clock
        self.rightPinchDistance = rightPinchDistance
        self.leftPinchDistance = leftPinchDistance
    }

    public func pointerTipTransform() -> Transform {
        pointerPath.transform(at: Float(clock.time))
    }
}

// MARK: - EntityPathDriver

/// Drives an entity's world-space position (and optionally orientation) along a
/// `MotionPath` each simulation tick via a registered harness step.
///
/// Use this to give NPCs, projectiles, or any reference object a deterministic scripted
/// trajectory — ideal for testing systems that react to moving targets.
///
/// ```swift
/// let patrolRoute = MotionPath.waypoints(
///     [[0,0,0], [5,0,0], [5,0,5], [0,0,5]], duration: 4.0
/// )
/// let clock = FrameClock()
/// let driver = EntityPathDriver(entity: npc, path: patrolRoute, clock: clock)
/// let harness = SystemHarness(scene: scene, clock: clock)
/// harness.register(driver.asStep())   // npc moves on the path every tick
///
/// let recorder = PathRecorder(entity: avatar, clock: clock)
/// harness.register(recorder.asStep())
///
/// harness.tick(frames: 360)   // 4 seconds
/// ```
///
/// > **Tip:** Register the driver step **first**, then any reaction steps, then recorders.
/// > That way reaction logic sees the updated target position in the same frame.
@MainActor
public final class EntityPathDriver {

    /// The entity being driven along the path.
    public let entity: Entity

    /// The spatial path the entity follows.
    public let path: MotionPath

    private let clock: FrameClock

    /// When `true`, the entity's `orientation` is also set from the path keyframe rotation
    /// each tick. Defaults to `false` because most DSL-built paths use identity rotation.
    public var applyRotation: Bool

    /// - Parameters:
    ///   - entity: The entity to move along the path.
    ///   - path: The `MotionPath` to follow.
    ///   - clock: Shared simulation clock — must match the harness.
    ///   - applyRotation: Set to `true` to also write orientation from keyframe rotation.
    public init(entity: Entity, path: MotionPath, clock: FrameClock, applyRotation: Bool = false) {
        self.entity = entity
        self.path = path
        self.clock = clock
        self.applyRotation = applyRotation
    }

    /// Returns a `SystemStep` that moves the entity to its path-sampled position each tick.
    ///
    /// - Parameter name: Optional step name for test output. Defaults to `"drive(<name>)"`.
    public func asStep(name: String? = nil) -> SystemStep {
        let stepName = name ?? "drive(\(entity.name))"
        return SystemStep(stepName) { [weak self] _, _ in
            guard let self else { return }
            let (pos, rot) = self.path.pose(at: Float(self.clock.time))
            // MotionPath poses are world-space; entity.position/.orientation are parent-relative.
            // Write through the world-relative setters so a driven entity under a transformed
            // parent lands on the path, matching this type's documented "world-space" contract.
            self.entity.setPosition(pos, relativeTo: nil)
            if self.applyRotation { self.entity.setOrientation(rot, relativeTo: nil) }
        }
    }
}
