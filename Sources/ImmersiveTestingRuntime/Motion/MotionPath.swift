import RealityKit
import simd

// MARK: - PathKeyframe

/// A single pose sample on a `MotionPath`: world-space position and orientation at a
/// given time. Build sequences of keyframes via `MotionPath`'s static factories or
/// the `@PathBuilder` DSL.
public struct PathKeyframe: Sendable {
    /// Seconds from the start of the path.
    public var time: Float
    /// World-space position in metres.
    public var position: SIMD3<Float>
    /// Orientation as a unit quaternion. Defaults to identity (no rotation).
    public var rotation: simd_quatf

    public init(
        time: Float,
        position: SIMD3<Float>,
        rotation: simd_quatf = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
    ) {
        self.time = time
        self.position = position
        self.rotation = rotation
    }
}

// MARK: - MotionPath

/// An ordered, time-indexed sequence of `PathKeyframe`s sampled at arbitrary times via
/// linear interpolation (position) and slerp (orientation). Use as the authoritative
/// spatial description of any simulated trajectory — NPC routes, projectile arcs, device
/// pose sweeps — so tests can compare against it precisely.
///
/// **Three construction styles:**
///
/// 1. Direct keyframes (lowest level):
/// ```swift
/// let path = MotionPath(keyframes: [
///     PathKeyframe(time: 0,   position: [0, 0, 0]),
///     PathKeyframe(time: 2.0, position: [10, 0, 0]),
/// ])
/// ```
///
/// 2. Static factories for common shapes:
/// ```swift
/// let straight = MotionPath.linear(from: [0,0,0], to: [10,0,0], duration: 2.0)
/// let orbit    = MotionPath.circle(center: .zero, radius: 5, duration: 4.0)
/// let route    = MotionPath.waypoints([[0,0,0],[5,0,0],[5,0,5]], duration: 3.0)
/// ```
///
/// 3. `@PathBuilder` DSL — chain segments from a starting point ("draw" the path):
/// ```swift
/// let complex = MotionPath(from: [0, 0, 0]) {
///     PathSegment.move(to: [5, 0, 0], duration: 1.0)
///     PathSegment.arc(center: [5, 0, 5], toAngle: .pi, radius: 5, duration: 2.0)
///     PathSegment.curve(via: [0, 2, 5], to: [0, 0, 0], duration: 1.5)
///     PathSegment.pause(duration: 0.5)
/// }
/// ```
public struct MotionPath: Sendable {

    // MARK: - Storage

    /// Keyframes in ascending time order.
    public private(set) var keyframes: [PathKeyframe]

    // MARK: - Init

    /// Creates a `MotionPath` from an explicit array of keyframes. Keyframes are sorted
    /// by time automatically; duplicate times are allowed (instantaneous transitions).
    public init(keyframes: [PathKeyframe]) {
        self.keyframes = keyframes.sorted { $0.time < $1.time }
    }

    // MARK: - Properties

    /// Total duration in seconds (time of the last keyframe, or 0 if empty).
    public var duration: Float { keyframes.last?.time ?? 0 }

    /// Cumulative arc length of the position curve in metres (piecewise linear).
    public var totalDistance: Float {
        guard keyframes.count > 1 else { return 0 }
        return zip(keyframes, keyframes.dropFirst())
            .reduce(0) { acc, pair in acc + distance(pair.0.position, pair.1.position) }
    }

    /// Maximum instantaneous speed (m/s) between any two consecutive keyframes.
    public var maxSpeed: Float {
        guard keyframes.count > 1 else { return 0 }
        return zip(keyframes, keyframes.dropFirst()).map { a, b -> Float in
            let dt = b.time - a.time
            return dt > 0 ? distance(a.position, b.position) / dt : 0
        }.max() ?? 0
    }

    /// Mean speed over the full path: `totalDistance / duration`, in m/s.
    public var averageSpeed: Float {
        guard duration > 0 else { return 0 }
        return totalDistance / duration
    }

    // MARK: - Sampling

    /// Returns the interpolated position and orientation at `queryTime` seconds.
    /// Clamps to the path's time range — no extrapolation.
    ///
    /// Position is linearly interpolated; orientation uses spherical linear interpolation
    /// (slerp) to avoid gimbal lock.
    public func pose(at queryTime: Float) -> (position: SIMD3<Float>, rotation: simd_quatf) {
        let identity = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
        guard !keyframes.isEmpty else { return (.zero, identity) }
        guard keyframes.count > 1 else { return (keyframes[0].position, keyframes[0].rotation) }

        let clamped = max(keyframes.first!.time, min(keyframes.last!.time, queryTime))

        guard let loIdx = keyframes.lastIndex(where: { $0.time <= clamped }) else {
            return (keyframes[0].position, keyframes[0].rotation)
        }
        let hiIdx = min(loIdx + 1, keyframes.count - 1)
        guard loIdx != hiIdx else {
            return (keyframes[loIdx].position, keyframes[loIdx].rotation)
        }

        let a = keyframes[loIdx], b = keyframes[hiIdx]
        let span = b.time - a.time
        let t = span > 0 ? (clamped - a.time) / span : 0

        let pos = a.position + (b.position - a.position) * t
        let rot = simd_slerp(a.rotation, b.rotation, t)
        return (pos, rot)
    }

    /// A RealityKit `Transform` sampled at `queryTime`. Rotation is identity if
    /// keyframes carry no meaningful orientation (e.g. auto-generated DSL paths).
    public func transform(at queryTime: Float) -> Transform {
        let (pos, rot) = pose(at: queryTime)
        return Transform(rotation: rot, translation: pos)
    }

    // MARK: - DSL init

    /// Builds a `MotionPath` by chaining `PathSegment`s from `startPosition`.
    ///
    /// Each segment begins exactly where the previous one ended, so the resulting path
    /// is always continuous. Use this to "draw" a path from high-level building blocks
    /// rather than specifying raw keyframes.
    ///
    /// ```swift
    /// let patrol = MotionPath(from: [0, 0, 0]) {
    ///     PathSegment.move(to: [8, 0, 0],  duration: 2.0)   // straight
    ///     PathSegment.arc(center: [8, 0, 4], toAngle: .pi,  // semicircle
    ///                     radius: 4, duration: 2.0)
    ///     PathSegment.curve(via: [4, 0, 10], to: [0, 0, 0], // bezier home
    ///                       duration: 2.0)
    ///     PathSegment.pause(duration: 1.0)                   // wait at start
    /// }
    /// ```
    public init(from startPosition: SIMD3<Float> = .zero, @PathBuilder _ content: () -> [PathSegment]) {
        let identity = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
        var kfs: [PathKeyframe] = [PathKeyframe(time: 0, position: startPosition, rotation: identity)]
        var currentTime: Float = 0
        var currentPos = startPosition

        for segment in content() {
            segment.apply(
                currentPos: &currentPos,
                currentTime: &currentTime,
                keyframes: &kfs,
                identity: identity
            )
        }

        self.keyframes = kfs
    }
}

// MARK: - Static Factories

extension MotionPath {

    /// A straight-line path from `start` to `end` over `duration` seconds.
    public static func linear(from start: SIMD3<Float>, to end: SIMD3<Float>, duration: Float) -> MotionPath {
        MotionPath(keyframes: [
            PathKeyframe(time: 0, position: start),
            PathKeyframe(time: duration, position: end),
        ])
    }

    /// A circular arc in the XZ plane.
    ///
    /// - Parameters:
    ///   - center: Centre of the circle.
    ///   - radius: Distance from centre to path.
    ///   - startAngle: Starting angle in radians (from +X axis, measured in XZ plane).
    ///   - endAngle: Ending angle in radians. Pass `startAngle + 2π` for a full loop.
    ///   - height: Constant Y value for the arc.
    ///   - duration: Time to traverse the arc.
    ///   - segments: Keyframe count — higher values give smoother interpolation.
    public static func arc(
        center: SIMD3<Float>,
        radius: Float,
        startAngle: Float,
        endAngle: Float,
        height: Float = 0,
        duration: Float,
        segments: Int = 16
    ) -> MotionPath {
        let steps = max(2, segments)
        let kfs = (0...steps).map { i -> PathKeyframe in
            let t = Float(i) / Float(steps)
            let angle = startAngle + (endAngle - startAngle) * t
            return PathKeyframe(
                time: duration * t,
                position: SIMD3(center.x + cos(angle) * radius, center.y + height, center.z + sin(angle) * radius)
            )
        }
        return MotionPath(keyframes: kfs)
    }

    /// A full circle in the XZ plane, returning exactly to the start point.
    public static func circle(
        center: SIMD3<Float>,
        radius: Float,
        height: Float = 0,
        duration: Float,
        segments: Int = 32
    ) -> MotionPath {
        arc(center: center, radius: radius, startAngle: 0, endAngle: 2 * .pi,
            height: height, duration: duration, segments: segments)
    }

    /// A path through explicit waypoints with time evenly distributed across segments.
    ///
    /// ```swift
    /// let route = MotionPath.waypoints([[0,0,0],[5,0,0],[5,0,5],[0,0,5]], duration: 4.0)
    /// ```
    public static func waypoints(_ positions: [SIMD3<Float>], duration: Float) -> MotionPath {
        guard positions.count > 1 else {
            return MotionPath(keyframes: positions.map { PathKeyframe(time: 0, position: $0) })
        }
        let segTime = duration / Float(positions.count - 1)
        return MotionPath(keyframes: positions.enumerated().map { i, pos in
            PathKeyframe(time: Float(i) * segTime, position: pos)
        })
    }
}

// MARK: - PathSegment

/// A single building block in a `@PathBuilder` path chain.
///
/// Each segment is applied sequentially, starting from the position left by the
/// previous segment. All rotations in DSL-built paths are identity — override with
/// explicit `PathKeyframe` arrays if orientation matters for your test.
///
/// ```swift
/// MotionPath(from: [0, 0, 0]) {
///     PathSegment.move(to: [5, 0, 0], duration: 1.0)
///     PathSegment.arc(center: [5, 0, 5], toAngle: .pi / 2, radius: 5, duration: 1.5)
///     PathSegment.curve(via: [3, 2, 8], to: [0, 0, 8], duration: 1.0)
///     PathSegment.pause(duration: 0.5)
/// }
/// ```
public struct PathSegment: Sendable {

    enum Kind: Sendable {
        case move(to: SIMD3<Float>, duration: Float)
        case arc(center: SIMD3<Float>, toAngle: Float, radius: Float,
                 duration: Float, heightDelta: Float, segments: Int)
        case curve(via: SIMD3<Float>, to: SIMD3<Float>, duration: Float, samples: Int)
        case pause(duration: Float)
    }

    let kind: Kind

    // MARK: Factories

    /// Moves in a straight line to `destination` over `duration` seconds.
    public static func move(to destination: SIMD3<Float>, duration: Float) -> PathSegment {
        PathSegment(kind: .move(to: destination, duration: duration))
    }

    /// Arcs around `center` in the XZ plane, sweeping to `toAngle` (radians from +X axis).
    ///
    /// The start angle is inferred automatically from the current path position relative to
    /// `center`, so the arc begins exactly where the previous segment ended and the path
    /// remains seamlessly continuous.
    ///
    /// - Parameters:
    ///   - center: Centre point of the circle in world space.
    ///   - toAngle: Target angle in radians (e.g. `.pi` to sweep 180°).
    ///   - radius: Arc radius. Override if the current position isn't exactly at `radius`
    ///     from `center`.
    ///   - duration: Time to sweep the arc.
    ///   - heightDelta: How much to rise/fall linearly over the arc duration.
    ///   - segments: Keyframe count for the approximation — more segments → smoother curve.
    public static func arc(
        center: SIMD3<Float>,
        toAngle: Float,
        radius: Float,
        duration: Float,
        heightDelta: Float = 0,
        segments: Int = 12
    ) -> PathSegment {
        PathSegment(kind: .arc(center: center, toAngle: toAngle, radius: radius,
                               duration: duration, heightDelta: heightDelta, segments: segments))
    }

    /// A quadratic Bézier curve from the current position, through `via`, to `to`.
    ///
    /// The control point `via` pulls the curve toward it without the path passing through it
    /// — ideal for smooth bends, projectile arcs, and NPC evasion manoeuvres.
    ///
    /// - Parameters:
    ///   - via: Bézier control point.
    ///   - to: Destination position.
    ///   - duration: Time to traverse the curve.
    ///   - samples: Keyframe count — more samples → more accurate arc-length distribution.
    public static func curve(
        via: SIMD3<Float>,
        to: SIMD3<Float>,
        duration: Float,
        samples: Int = 16
    ) -> PathSegment {
        PathSegment(kind: .curve(via: via, to: to, duration: duration, samples: samples))
    }

    /// Stays at the current position for `duration` seconds.
    public static func pause(duration: Float) -> PathSegment {
        PathSegment(kind: .pause(duration: duration))
    }

    // MARK: - Internal application

    /// Called by `MotionPath.init(from:_:)` to accumulate keyframes.
    func apply(
        currentPos: inout SIMD3<Float>,
        currentTime: inout Float,
        keyframes: inout [PathKeyframe],
        identity: simd_quatf
    ) {
        switch kind {
        case .move(let dest, let dur):
            currentTime += dur
            currentPos = dest
            keyframes.append(PathKeyframe(time: currentTime, position: dest, rotation: identity))

        case .pause(let dur):
            currentTime += dur
            keyframes.append(PathKeyframe(time: currentTime, position: currentPos, rotation: identity))

        case .arc(let center, let toAngle, let radius, let dur, let heightDelta, let segs):
            let startAngle = atan2(currentPos.z - center.z, currentPos.x - center.x)
            let startY = currentPos.y
            let steps = max(2, segs)
            for i in 1...steps {
                let t = Float(i) / Float(steps)
                let angle = startAngle + (toAngle - startAngle) * t
                let pos = SIMD3<Float>(
                    center.x + cos(angle) * radius,
                    startY + heightDelta * t,
                    center.z + sin(angle) * radius
                )
                keyframes.append(PathKeyframe(time: currentTime + dur * t, position: pos, rotation: identity))
            }
            currentTime += dur
            currentPos = keyframes.last!.position

        case .curve(let via, let dest, let dur, let samps):
            let p0 = currentPos
            let steps = max(2, samps)
            for i in 1...steps {
                let t = Float(i) / Float(steps)
                let u = 1 - t
                // Quadratic Bézier: (1-t)²·p0 + 2(1-t)t·via + t²·dest
                let pos = (u * u) * p0 + (2 * u * t) * via + (t * t) * dest
                keyframes.append(PathKeyframe(time: currentTime + dur * t, position: pos, rotation: identity))
            }
            currentTime += dur
            currentPos = dest
        }
    }
}

// MARK: - PathBuilder result builder

/// Composes `PathSegment` values into a `[PathSegment]` array for `MotionPath.init(from:_:)`.
@resultBuilder
public enum PathBuilder {
    public static func buildBlock(_ components: [PathSegment]...) -> [PathSegment] { components.flatMap { $0 } }
    public static func buildArray(_ components: [[PathSegment]]) -> [PathSegment] { components.flatMap { $0 } }
    public static func buildOptional(_ component: [PathSegment]?) -> [PathSegment] { component ?? [] }
    public static func buildEither(first: [PathSegment]) -> [PathSegment] { first }
    public static func buildEither(second: [PathSegment]) -> [PathSegment] { second }
    public static func buildExpression(_ e: PathSegment) -> [PathSegment] { [e] }
}
