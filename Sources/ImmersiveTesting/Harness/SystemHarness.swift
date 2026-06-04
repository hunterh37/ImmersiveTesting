import XCTest
import RealityKit
import ImmersiveTestingRuntime

// MARK: - SystemHarness

/// Drives ECS-style simulation steps frame-by-frame against a `TestScene`.
///
/// The harness owns a `FrameClock` and an ordered list of `SystemStep`s. Each `tick()`
/// call executes every step in registration order, then optionally checks a set of
/// `SceneInvariantSet` invariants — failing the current XCTest frame if any are violated.
///
/// ```swift
/// let scene = TestScene { /* … */ }
/// let harness = SystemHarness(scene: scene)
///
/// harness.registerStep("steering") { entities, dt in
///     for e in entities {
///         guard let proj = e.components[ProjectileComponent.self] else { continue }
///         e.position += proj.velocity * dt
///     }
/// }
///
/// harness.tick(frames: 60)
/// XCTAssertPosition(projectile, near: expectedTarget, within: 0.1)
/// ```
@MainActor
public final class SystemHarness {

    // MARK: - Public properties

    public let scene: TestScene
    public let clock: FrameClock

    /// The injected services every step receives. Defaults to a fully-fake environment.
    public let environment: any SceneEnvironment

    // MARK: - Private state

    private var steps: [SystemStep] = []

    // MARK: - Init

    public init(
        scene: TestScene,
        clock: FrameClock? = nil,
        environment: any SceneEnvironment = CompositeSceneEnvironment()
    ) {
        self.scene = scene
        self.clock = clock ?? FrameClock()
        self.environment = environment
    }

    // MARK: - Registration

    /// Appends a named simulation step executed each tick.
    public func registerStep(_ name: String, _ body: @MainActor @escaping ([Entity], Float) -> Void) {
        steps.append(SystemStep(name) { entities, dt in body(Array(entities), dt) })
    }

    /// Appends an environment-aware step. The closure receives the harness's injected
    /// `SceneEnvironment`, so systems that read device pose / hand input / RNG can be driven
    /// from scriptable fakes.
    ///
    /// ```swift
    /// harness.registerStep("chase") { entities, dt, env in
    ///     let player = env.worldTracking.devicePosition()
    ///     for e in entities where e.components[ZombieTag.self] != nil {
    ///         e.position += normalize(player - e.position) * dt
    ///     }
    /// }
    /// ```
    public func registerStep(_ name: String, _ body: @MainActor @escaping ([Entity], Float, any SceneEnvironment) -> Void) {
        steps.append(SystemStep(name) { entities, dt, env in body(Array(entities), dt, env) })
    }

    /// Appends a pre-built `SystemStep`.
    public func register(_ step: SystemStep) {
        steps.append(step)
    }

    // MARK: - Ticking

    /// Advances one frame: runs every registered step then ticks the clock.
    public func tick(invariants: SceneInvariantSet? = nil,
                     file: StaticString = #filePath, line: UInt = #line) {
        let entities = ArraySlice(scene.root.allEntities)
        let dt = clock.dt
        for step in steps { step.body(entities, dt, environment) }
        clock.tick()
        invariants?.check(scene.root, frame: clock.frame, file: file, line: line)
    }

    /// Advances `count` frames. If `invariants` is supplied, each frame is checked before
    /// advancing — test fails on the exact frame the invariant breaks.
    public func tick(frames count: Int,
                     invariants: SceneInvariantSet? = nil,
                     file: StaticString = #filePath, line: UInt = #line) {
        for _ in 0..<count {
            tick(invariants: invariants, file: file, line: line)
        }
    }

    /// Advances frames until `condition` returns true or `maxFrames` is reached.
    /// Fails the test if `maxFrames` is exhausted without the condition being met.
    @discardableResult
    public func tickUntil(
        _ description: String = "condition",
        maxFrames: Int = 600,
        invariants: SceneInvariantSet? = nil,
        condition: @MainActor () -> Bool,
        file: StaticString = #filePath, line: UInt = #line
    ) -> Int {
        for _ in 0..<maxFrames {
            if condition() { return clock.frame }
            tick(invariants: invariants, file: file, line: line)
        }
        XCTFail("'\(description)' never became true after \(maxFrames) frames", file: file, line: line)
        return clock.frame
    }
}
