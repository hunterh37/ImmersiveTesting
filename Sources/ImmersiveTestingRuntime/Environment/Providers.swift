import RealityKit
import simd

// MARK: - Dependency-injection provider protocols
//
// These four protocols isolate the runtime services an immersive RealityKit scene
// normally reaches for through singletons or live ARKit providers. By depending on a
// protocol instead of `WorldTrackingManager.shared` (or an ARKit `HandTrackingProvider`),
// a system or scene builder becomes drivable headlessly: tests inject scriptable fakes,
// production injects thin adapters over the real managers.
//
// **Why protocols and not the ARKit types?** The ImmersiveTesting package deliberately
// has no ARKit dependency so it runs on macOS CI. Every requirement here is expressed in
// RealityKit / simd value types (`Transform`, `SIMD3`) that exist headlessly. The app
// conforms its real `.shared` managers to these protocols; the package ships the fakes.

// MARK: WorldTrackingProviding

/// Supplies the device (head) pose. Production adapter wraps
/// `WorldTrackingManager.shared.getOriginFromDeviceTransform()`.
@MainActor
public protocol WorldTrackingProviding {
    /// The device transform in world (origin) space.
    func deviceTransform() -> Transform
}

public extension WorldTrackingProviding {
    /// Convenience: just the device translation — the common case for spawn-band math.
    func devicePosition() -> SIMD3<Float> { deviceTransform().translation }
}

// MARK: SceneEffectsProviding

/// Drives whole-scene visual effects (e.g. scene-reconstruction glitch cycles). Production
/// adapter wraps `SceneReconstructionManager.shared`; the fake records calls for assertion.
@MainActor
public protocol SceneEffectsProviding: AnyObject {
    /// A persistent post-effect intensity in `0...1`.
    var persistentIntensity: Float { get set }

    /// Start a named effect (the app maps the identifier to its own `GlitchType` enum).
    func startEffect(named identifier: String)
}

// MARK: HandTrackingProviding

/// Supplies hand-derived inputs the gameplay reads each frame. Production adapter wraps the
/// app's `HandGestureModel` / ARKit hand tracking; the fake lets tests script pinches.
@MainActor
public protocol HandTrackingProviding {
    /// Thumb-to-index distance on the right (shooting) hand, in metres.
    var rightPinchDistance: Float { get }

    /// Thumb-to-index distance on the left (reload) hand, in metres.
    var leftPinchDistance: Float { get }

    /// World transform of the gun tip where projectiles spawn.
    func gunTipTransform() -> Transform
}

public extension HandTrackingProviding {
    /// Whether the right hand is pinched past the shooting threshold (matches the game's
    /// `< 0.09 m` rule by default).
    func isRightPinching(threshold: Float = 0.09) -> Bool { rightPinchDistance < threshold }

    /// Whether the left hand is pinched past `threshold`.
    func isLeftPinching(threshold: Float = 0.09) -> Bool { leftPinchDistance < threshold }
}

// MARK: RandomProviding

/// A source of pseudo-randomness for spawn placement, jitter, AI choices, etc. Inject a
/// seedable fake to make otherwise-random scenes deterministic and reproducible in CI.
@MainActor
public protocol RandomProviding {
    /// The next value in `[0, 1)`.
    func next() -> Float
}

public extension RandomProviding {
    /// A value in the closed range `[range.lowerBound, range.upperBound]`.
    func next(in range: ClosedRange<Float>) -> Float {
        range.lowerBound + next() * (range.upperBound - range.lowerBound)
    }

    /// A random angle in `[0, 2π)`.
    func angle() -> Float { next() * 2 * .pi }

    /// A unit vector on the XZ plane (ground ring) — handy for ringing zombies around the
    /// player at a fixed radius.
    func unitVectorXZ() -> SIMD3<Float> {
        let a = angle()
        return SIMD3(cos(a), 0, sin(a))
    }
}
