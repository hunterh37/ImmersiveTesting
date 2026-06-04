import XCTest
import simd
import RealityKit
import ImmersiveTestingRuntime

// MARK: - Position / distance

/// Asserts an entity's world position is near a target point.
@MainActor
public func XCTAssertPosition(
    _ entity: Entity,
    near target: SIMD3<Float>,
    within tolerance: Float,
    _ message: String = "",
    file: StaticString = #filePath, line: UInt = #line
) {
    let d = simd_distance(entity.worldPosition, target)
    XCTAssertLessThanOrEqual(
        d, tolerance,
        message.isEmpty
            ? "\(entity.name.isEmpty ? "entity" : entity.name) at \(entity.worldPosition) is \(d)m from \(target), tolerance \(tolerance)m"
            : message,
        file: file, line: line
    )
}

/// Asserts an entity's world position equals a target within per-component accuracy.
@MainActor
public func XCTAssertWorldPosition(
    _ entity: Entity,
    equals target: SIMD3<Float>,
    accuracy: Float,
    file: StaticString = #filePath, line: UInt = #line
) {
    let p = entity.worldPosition
    XCTAssertEqual(p.x, target.x, accuracy: accuracy, "x", file: file, line: line)
    XCTAssertEqual(p.y, target.y, accuracy: accuracy, "y", file: file, line: line)
    XCTAssertEqual(p.z, target.z, accuracy: accuracy, "z", file: file, line: line)
}

/// Asserts the distance between two entities is below a maximum.
@MainActor
public func XCTAssertDistance(
    _ a: Entity, to b: Entity,
    lessThan maximum: Float,
    file: StaticString = #filePath, line: UInt = #line
) {
    let d = simd_distance(a.worldPosition, b.worldPosition)
    XCTAssertLessThan(d, maximum, "distance \(d)m not < \(maximum)m", file: file, line: line)
}

// MARK: - Orientation

/// Asserts an entity's forward (-Z) points toward a target entity within a tolerance.
@MainActor
public func XCTAssertFacing(
    _ entity: Entity, towards target: Entity,
    tolerance: Angle,
    file: StaticString = #filePath, line: UInt = #line
) {
    let toTarget = target.worldPosition - entity.worldPosition
    let angle = angleBetween(entity.worldForward, toTarget)
    XCTAssertLessThanOrEqual(
        angle.degrees, tolerance.degrees,
        "facing off by \(String(format: "%.1f", angle.degrees))°, tolerance \(tolerance.degrees)°",
        file: file, line: line
    )
}

/// Asserts an entity's up axis is within tolerance of world +Y.
@MainActor
public func XCTAssertUpright(
    _ entity: Entity,
    tolerance: Angle,
    file: StaticString = #filePath, line: UInt = #line
) {
    let angle = angleBetween(entity.worldUp, [0, 1, 0])
    XCTAssertLessThanOrEqual(
        angle.degrees, tolerance.degrees,
        "tilted \(String(format: "%.1f", angle.degrees))° from upright, tolerance \(tolerance.degrees)°",
        file: file, line: line
    )
}

// MARK: - Scale

/// Asserts an entity's world (uniform) scale equals a value within accuracy.
@MainActor
public func XCTAssertWorldScale(
    _ entity: Entity,
    equals expected: Float, accuracy: Float,
    file: StaticString = #filePath, line: UInt = #line
) {
    XCTAssertEqual(entity.worldScale, expected, accuracy: accuracy, file: file, line: line)
}

/// Asserts every entity in the subtree has a finite (non-NaN/inf) transform.
@MainActor
public func XCTAssertFiniteTransforms(
    _ root: Entity,
    file: StaticString = #filePath, line: UInt = #line
) {
    let bad = root.allEntities.filter { !$0.worldPosition.isFinite }
    XCTAssertTrue(
        bad.isEmpty,
        "non-finite transforms: \(bad.map { $0.name })",
        file: file, line: line
    )
}
