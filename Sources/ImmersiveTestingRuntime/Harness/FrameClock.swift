import Foundation

/// Deterministic, seedable time source for headless ECS system tests.
///
/// All simulation runs at the fixed `deltaTime` you specify (default: 1/90 s, matching
/// visionOS). Advance it frame-by-frame or in bulk; query `time` / `frame` to verify
/// time-dependent behaviour (cooldowns, AI timers, animation curves, etc.).
///
/// ```swift
/// let clock = FrameClock()           // 90 Hz by default
/// clock.advance(frames: 30)          // 1/3 second of simulated time
/// XCTAssertGreaterThan(clock.time, 0.33 - 0.01)
/// ```
@MainActor
public final class FrameClock {

    // MARK: - Public state

    /// Total simulated time in seconds since the last `reset()`.
    public private(set) var time: Double = 0

    /// Total frames advanced since the last `reset()`.
    public private(set) var frame: Int = 0

    /// The delta time applied to each `advance()` call (in seconds).
    public var deltaTime: Double

    // MARK: - Init

    /// Creates a clock at 90 Hz (Apple Vision Pro's standard rate) by default.
    public init(deltaTime: Double = 1.0 / 90.0) {
        self.deltaTime = deltaTime
    }

    // MARK: - Advancing

    /// Advances by exactly one frame using `deltaTime`.
    public func tick() {
        time += deltaTime
        frame += 1
    }

    /// Advances by `count` frames, each at `deltaTime`.
    public func advance(frames count: Int) {
        precondition(count >= 0, "frame count must be non-negative")
        for _ in 0..<count { tick() }
    }

    /// Advances by a single frame using a custom delta time (e.g. a hiccup frame).
    public func tick(deltaTime customDt: Double) {
        time += customDt
        frame += 1
    }

    // MARK: - Utilities

    /// Resets time and frame counter to zero.
    public func reset() {
        time = 0
        frame = 0
    }

    /// Returns the `deltaTime` as a `Float` (for passing to RealityKit / SIMD math).
    public var dt: Float { Float(deltaTime) }
}
