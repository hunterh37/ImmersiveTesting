import simd

// MARK: - SpatialRegion

/// A named spatial volume for asserting containment of entities or points.
///
/// Used with `XCTAssertEntity(_:within:)`, `XCTAssertAllEntities(_:in:within:)`, and
/// `SceneInvariant.withinRegion(_:region:entities:)` to express "no zombie escapes the
/// arena" or "all pickups spawn within the play area" as a single reusable region value.
///
/// ```swift
/// let arena = SpatialRegion.sphere(center: .zero, radius: 10, name: "arena")
///
/// // Point containment:
/// XCTAssertTrue(arena.contains(zombie.position(relativeTo: nil)))
///
/// // Per-component assertion:
/// XCTAssertAllEntities(ZombieTag.self, in: scene.root, within: arena)
///
/// // Per-frame invariant (checked every tick via SceneInvariantSet):
/// let inv = SceneInvariant.withinRegion("zombies in arena", region: arena) { root in
///     root.entities(with: ZombieTag.self)
/// }
/// harness.tick(frames: 300, invariants: SceneInvariantSet { inv })
/// ```
public struct SpatialRegion: Sendable {

    // MARK: - Shape

    /// The underlying geometric shape of this region.
    public enum Shape: Sendable {
        /// A sphere defined by its centre and radius.
        case sphere(center: SIMD3<Float>, radius: Float)
        /// An axis-aligned box defined by its centre and half-extents along each axis.
        case box(center: SIMD3<Float>, halfExtents: SIMD3<Float>)
        /// A vertical cylinder. Pass `halfHeight: .infinity` for an unbounded vertical column.
        case cylinder(center: SIMD3<Float>, radius: Float, halfHeight: Float)
    }

    // MARK: - Properties

    /// Human-readable identifier shown in assertion failure messages.
    public let name: String
    /// The geometric shape of this region.
    public let shape: Shape

    // MARK: - Factories

    /// A spherical region.
    ///
    /// - Parameters:
    ///   - center: Centre of the sphere in world space.
    ///   - radius: Radius in metres. Points on the surface are considered inside.
    ///   - name: Label used in assertion failure messages.
    public static func sphere(
        center: SIMD3<Float>,
        radius: Float,
        name: String = "sphere"
    ) -> SpatialRegion {
        SpatialRegion(name: name, shape: .sphere(center: center, radius: radius))
    }

    /// An axis-aligned box region.
    ///
    /// - Parameters:
    ///   - center: Box centre in world space.
    ///   - size: **Full** extents along each axis (width × height × depth).
    ///   - name: Label used in assertion failure messages.
    public static func box(
        center: SIMD3<Float>,
        size: SIMD3<Float>,
        name: String = "box"
    ) -> SpatialRegion {
        SpatialRegion(name: name, shape: .box(center: center, halfExtents: size * 0.5))
    }

    /// A vertical cylinder aligned with the Y axis.
    ///
    /// - Parameters:
    ///   - center: Centre of the cylinder in world space.
    ///   - radius: Cylinder radius in metres.
    ///   - halfHeight: Half the total height. Pass `.infinity` for an unbounded column
    ///     (useful when you only care about XZ containment).
    ///   - name: Label used in assertion failure messages.
    public static func cylinder(
        center: SIMD3<Float>,
        radius: Float,
        halfHeight: Float = .infinity,
        name: String = "cylinder"
    ) -> SpatialRegion {
        SpatialRegion(name: name, shape: .cylinder(center: center, radius: radius, halfHeight: halfHeight))
    }

    // MARK: - Containment

    /// Returns `true` if `point` lies at or within the boundary of this region.
    public func contains(_ point: SIMD3<Float>) -> Bool {
        switch shape {
        case .sphere(let center, let radius):
            return distance(point, center) <= radius

        case .box(let center, let halfExtents):
            let d = abs(point - center)
            return d.x <= halfExtents.x && d.y <= halfExtents.y && d.z <= halfExtents.z

        case .cylinder(let center, let radius, let halfHeight):
            let xzDist = length(SIMD2<Float>(point.x - center.x, point.z - center.z))
            return xzDist <= radius && abs(point.y - center.y) <= halfHeight
        }
    }

    /// Returns `true` if every point in `points` lies within this region.
    public func containsAll(_ points: [SIMD3<Float>]) -> Bool {
        points.allSatisfy { contains($0) }
    }

    /// Returns the subset of `points` that fall **outside** this region.
    public func violations(in points: [SIMD3<Float>]) -> [SIMD3<Float>] {
        points.filter { !contains($0) }
    }
}
