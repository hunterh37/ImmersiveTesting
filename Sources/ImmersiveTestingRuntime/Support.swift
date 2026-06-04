import Foundation
import simd
import RealityKit

/// A small angle type so tolerances are explicit (no raw-radian foot-guns).
public struct Angle: Equatable, Sendable {
    public var radians: Double
    public init(radians: Double) { self.radians = radians }
    public static func radians(_ r: Double) -> Angle { Angle(radians: r) }
    public static func degrees(_ d: Double) -> Angle { Angle(radians: d * .pi / 180) }
    public var degrees: Double { radians * 180 / .pi }
}

extension SIMD3 where Scalar == Float {
    public var isFinite: Bool { x.isFinite && y.isFinite && z.isFinite }
}

@MainActor
extension Entity {
    /// World-space translation (relative to nil).
    public var worldPosition: SIMD3<Float> { position(relativeTo: nil) }

    /// World-space uniform scale (mean of the three axes).
    public var worldScale: Float {
        let s = scale(relativeTo: nil)
        return (s.x + s.y + s.z) / 3
    }

    /// All entities in the subtree rooted at this entity, including self.
    public var allEntities: [Entity] {
        var result = [self]
        for child in children { result.append(contentsOf: child.allEntities) }
        return result
    }

    /// Forward (-Z) direction in world space.
    public var worldForward: SIMD3<Float> {
        let m = transformMatrix(relativeTo: nil)
        return normalize(-SIMD3(m.columns.2.x, m.columns.2.y, m.columns.2.z))
    }

    /// Up (+Y) direction in world space.
    public var worldUp: SIMD3<Float> {
        let m = transformMatrix(relativeTo: nil)
        return normalize(SIMD3(m.columns.1.x, m.columns.1.y, m.columns.1.z))
    }

    /// Entities in this subtree carrying the given component type.
    public func entities<C: Component>(with type: C.Type) -> [Entity] {
        allEntities.filter { $0.components[type] != nil }
    }
}

@MainActor
public func angleBetween(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Angle {
    let na = normalize(a), nb = normalize(b)
    let dot = max(-1, min(1, simd_dot(na, nb)))
    return Angle(radians: Double(acos(dot)))
}
