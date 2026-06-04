import XCTest
import RealityKit
import ImmersiveTestingRuntime

/// Asserts an entity's collision filter group contains the given group bits.
@MainActor
public func XCTAssertColliderGroup(
    _ entity: Entity, contains group: CollisionGroup,
    file: StaticString = #filePath, line: UInt = #line
) {
    guard let c = entity.components[CollisionComponent.self] else {
        XCTFail("\(entity.name) has no CollisionComponent", file: file, line: line)
        return
    }
    XCTAssertEqual(
        c.filter.group.rawValue & group.rawValue, group.rawValue,
        "\(entity.name) group \(c.filter.group.rawValue) does not contain \(group.rawValue)",
        file: file, line: line
    )
}

/// Asserts two entities *would* collide: each one's group intersects the other's mask.
@MainActor
public func XCTAssertCollides(
    _ a: Entity, with b: Entity,
    file: StaticString = #filePath, line: UInt = #line
) {
    guard let fa = a.components[CollisionComponent.self]?.filter,
          let fb = b.components[CollisionComponent.self]?.filter else {
        XCTFail("both entities need a CollisionComponent", file: file, line: line)
        return
    }
    let aHitsB = fa.mask.rawValue & fb.group.rawValue != 0
    let bHitsA = fb.mask.rawValue & fa.group.rawValue != 0
    XCTAssertTrue(
        aHitsB && bHitsA,
        "\(a.name) and \(b.name) would not collide (filter mismatch)",
        file: file, line: line
    )
}

/// Asserts two entities would NOT collide.
///
/// - Note: If either entity has no `CollisionComponent` this assertion passes trivially —
///   a missing collider cannot participate in a collision. If you suspect a collider was
///   accidentally omitted, pair this with `XCTAssertNoCollider` to make the absence explicit.
@MainActor
public func XCTAssertNoCollision(
    _ a: Entity, with b: Entity,
    file: StaticString = #filePath, line: UInt = #line
) {
    guard let fa = a.components[CollisionComponent.self]?.filter,
          let fb = b.components[CollisionComponent.self]?.filter else {
        return // no collider → no collision, trivially passes (see note above)
    }
    let aHitsB = fa.mask.rawValue & fb.group.rawValue != 0
    let bHitsA = fb.mask.rawValue & fa.group.rawValue != 0
    XCTAssertFalse(
        aHitsB && bHitsA,
        "\(a.name) and \(b.name) unexpectedly collide",
        file: file, line: line
    )
}
