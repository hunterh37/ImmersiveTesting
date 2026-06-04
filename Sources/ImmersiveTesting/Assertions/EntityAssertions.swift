import XCTest
import RealityKit
import ImmersiveTestingRuntime

// MARK: - Name

/// Asserts an optional entity is non-nil and has the expected name.
/// Great for `scene["some.path"]` lookups that must resolve to a specific node.
@MainActor
public func XCTAssertEntityName(
    _ entity: Entity?,
    _ expectedName: String,
    file: StaticString = #filePath, line: UInt = #line
) {
    guard let entity else {
        XCTFail("entity is nil — expected entity named \"\(expectedName)\"", file: file, line: line)
        return
    }
    XCTAssertEqual(entity.name, expectedName, file: file, line: line)
}

// MARK: - Children

/// Asserts a parent has exactly `count` direct children.
@MainActor
public func XCTAssertChildCount(
    _ parent: Entity,
    _ count: Int,
    file: StaticString = #filePath, line: UInt = #line
) {
    XCTAssertEqual(
        parent.children.count, count,
        "\(parent.name) has \(parent.children.count) children, expected \(count)",
        file: file, line: line
    )
}

/// Asserts a parent has at least one direct child.
@MainActor
public func XCTAssertHasChildren(
    _ parent: Entity,
    file: StaticString = #filePath, line: UInt = #line
) {
    XCTAssertFalse(
        parent.children.isEmpty,
        "\(parent.name) has no children",
        file: file, line: line
    )
}

/// Asserts a parent has no children.
@MainActor
public func XCTAssertNoChildren(
    _ parent: Entity,
    file: StaticString = #filePath, line: UInt = #line
) {
    XCTAssertTrue(
        parent.children.isEmpty,
        "\(parent.name) has \(parent.children.count) unexpected children: \(parent.children.map(\.name))",
        file: file, line: line
    )
}

// MARK: - Enabled / visibility

/// Asserts `entity.isEnabled` is true.
@MainActor
public func XCTAssertEnabled(
    _ entity: Entity,
    file: StaticString = #filePath, line: UInt = #line
) {
    XCTAssertTrue(entity.isEnabled, "\(entity.name) should be enabled", file: file, line: line)
}

/// Asserts `entity.isEnabled` is false.
@MainActor
public func XCTAssertDisabled(
    _ entity: Entity,
    file: StaticString = #filePath, line: UInt = #line
) {
    XCTAssertFalse(entity.isEnabled, "\(entity.name) should be disabled", file: file, line: line)
}

// MARK: - Subtree counts

/// Asserts the total entity count in a subtree (including root) equals `expected`.
@MainActor
public func XCTAssertSubtreeSize(
    _ root: Entity,
    equals expected: Int,
    file: StaticString = #filePath, line: UInt = #line
) {
    let actual = root.allEntities.count
    XCTAssertEqual(
        actual, expected,
        "subtree of \"\(root.name)\" has \(actual) entities, expected \(expected)",
        file: file, line: line
    )
}

// MARK: - Scale

/// Asserts an entity's local (not world) scale is uniform within accuracy.
@MainActor
public func XCTAssertUniformScale(
    _ entity: Entity,
    equals expected: Float,
    accuracy: Float,
    file: StaticString = #filePath, line: UInt = #line
) {
    let s = entity.scale
    XCTAssertEqual(s.x, expected, accuracy: accuracy, "x scale", file: file, line: line)
    XCTAssertEqual(s.y, expected, accuracy: accuracy, "y scale", file: file, line: line)
    XCTAssertEqual(s.z, expected, accuracy: accuracy, "z scale", file: file, line: line)
}

// MARK: - Collision mask

/// Asserts an entity's collision *mask* (the groups it hits) contains the given group.
@MainActor
public func XCTAssertColliderMask(
    _ entity: Entity, contains group: CollisionGroup,
    file: StaticString = #filePath, line: UInt = #line
) {
    guard let c = entity.components[CollisionComponent.self] else {
        XCTFail("\(entity.name) has no CollisionComponent", file: file, line: line)
        return
    }
    XCTAssertEqual(
        c.filter.mask.rawValue & group.rawValue, group.rawValue,
        "\(entity.name) mask \(c.filter.mask.rawValue) does not contain \(group.rawValue)",
        file: file, line: line
    )
}

/// Asserts an entity has NO collision component at all.
@MainActor
public func XCTAssertNoCollider(
    _ entity: Entity,
    file: StaticString = #filePath, line: UInt = #line
) {
    XCTAssertNil(
        entity.components[CollisionComponent.self],
        "\(entity.name) unexpectedly has a CollisionComponent",
        file: file, line: line
    )
}

// MARK: - Parent

/// Asserts an entity is the root (no parent).
@MainActor
public func XCTAssertRoot(
    _ entity: Entity,
    file: StaticString = #filePath, line: UInt = #line
) {
    XCTAssertNil(entity.parent, "\(entity.name) has parent \(entity.parent?.name ?? "?") — expected root", file: file, line: line)
}

/// Asserts an entity has a parent (is not the root).
@MainActor
public func XCTAssertHasParent(
    _ entity: Entity,
    file: StaticString = #filePath, line: UInt = #line
) {
    XCTAssertNotNil(entity.parent, "\(entity.name) has no parent — expected a non-root entity", file: file, line: line)
}
