import RealityKit
import simd

// MARK: - Scriptable fakes for the provider protocols
//
// Each fake is a reference type so a test can hold it, mutate its scripted state between
// ticks, and observe what the system-under-test did. These are the headless stand-ins for
// live ARKit / singleton services.

// MARK: FakeWorldTracking

/// A scriptable device-pose source. Set `transform` (or `position`) to teleport the
/// simulated head, then tick the harness to drive pose-dependent systems.
///
/// ```swift
/// let world = FakeWorldTracking()
/// world.position = [5, 1.6, 0]      // player walked right
/// harness.tick(frames: 90)
/// ```
@MainActor
public final class FakeWorldTracking: WorldTrackingProviding {
    /// The pose returned by `deviceTransform()`. Mutate freely between ticks.
    public var transform: Transform

    /// Convenience accessor/mutator for just the translation.
    public var position: SIMD3<Float> {
        get { transform.translation }
        set { transform.translation = newValue }
    }

    public init(transform: Transform = Transform()) {
        self.transform = transform
    }

    public func deviceTransform() -> Transform { transform }
}

// MARK: SpySceneEffects

/// Records every effect call so tests can assert *that* an effect fired without a renderer.
///
/// ```swift
/// let fx = SpySceneEffects()
/// viewModel.enterBossWave(effects: fx)
/// XCTAssertEqual(fx.startedEffects.last, "wiremeshCyberGreen")
/// ```
@MainActor
public final class SpySceneEffects: SceneEffectsProviding {
    public var persistentIntensity: Float = 0

    /// Names passed to `startEffect(named:)`, in call order.
    public private(set) var startedEffects: [String] = []

    public init() {}

    public func startEffect(named identifier: String) {
        startedEffects.append(identifier)
    }

    /// Forget all recorded calls (intensity is left untouched).
    public func reset() { startedEffects.removeAll() }
}

// MARK: ScriptedHands

/// A scriptable hand-input source. Drive a shot by closing the right pinch for a frame,
/// then re-opening it, mirroring a real pinch gesture.
///
/// ```swift
/// let hands = ScriptedHands()
/// hands.rightPinchDistance = 0.05   // closed → below the 0.09 threshold
/// harness.tick()                    // fire system spawns a projectile
/// hands.rightPinchDistance = 0.20   // open → ready for the next shot
/// ```
@MainActor
public final class ScriptedHands: HandTrackingProviding {
    public var rightPinchDistance: Float
    public var leftPinchDistance: Float
    public var gunTip: Transform

    public init(
        rightPinchDistance: Float = 1.0,   // open by default (no accidental fire)
        leftPinchDistance: Float = 1.0,
        gunTip: Transform = Transform()
    ) {
        self.rightPinchDistance = rightPinchDistance
        self.leftPinchDistance = leftPinchDistance
        self.gunTip = gunTip
    }

    public func gunTipTransform() -> Transform { gunTip }
}

// MARK: SeededRandom

/// A deterministic, seedable RNG (SplitMix64) producing `Float`s in `[0, 1)`. Two instances
/// with the same seed yield the same sequence, making "random" spawn rings reproducible in
/// CI — re-running a flaky-looking layout failure replays the exact same scene.
///
/// ```swift
/// let rng = SeededRandom(seed: 42)
/// let scene = SurvivalSceneBuilder().build(.init(), env: .fake(random: rng))
/// // identical every run
/// ```
@MainActor
public final class SeededRandom: RandomProviding {
    private var state: UInt64

    public init(seed: UInt64 = 0x9E37_79B9_7F4A_7C15) {
        self.state = seed
    }

    public func next() -> Float {
        state = state &+ 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        z = z ^ (z >> 31)
        // Take the top 24 bits → an exact float in [0, 1) (24-bit mantissa, no overflow).
        return Float(z >> 40) * (1.0 / Float(1 << 24))
    }
}
