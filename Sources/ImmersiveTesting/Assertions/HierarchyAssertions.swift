import XCTest
import RealityKit
import ImmersiveTestingRuntime

/// Asserts `child` is a direct child of `parent`.
@MainActor
public func XCTAssertChild(
    _ child: Entity, of parent: Entity,
    file: StaticString = #filePath, line: UInt = #line
) {
    XCTAssertTrue(
        parent.children.contains(where: { $0 === child }),
        "\(child.name) is not a direct child of \(parent.name)",
        file: file, line: line
    )
}

/// Asserts `descendant` appears somewhere in the subtree of `ancestor`.
@MainActor
public func XCTAssertDescendant(
    _ descendant: Entity, of ancestor: Entity,
    file: StaticString = #filePath, line: UInt = #line
) {
    XCTAssertTrue(
        ancestor.allEntities.contains(where: { $0 === descendant }),
        "\(descendant.name) is not a descendant of \(ancestor.name)",
        file: file, line: line
    )
}

/// Asserts an entity with the given name exists in the subtree.
@MainActor
public func XCTAssertEntityExists(
    _ root: Entity, named name: String,
    file: StaticString = #filePath, line: UInt = #line
) {
    XCTAssertNotNil(
        root.findEntity(named: name),
        "no entity named \"\(name)\" in subtree of \(root.name)",
        file: file, line: line
    )
}

/// Asserts NO entity with the given name exists in the subtree.
@MainActor
public func XCTAssertNoEntity(
    _ root: Entity, named name: String,
    file: StaticString = #filePath, line: UInt = #line
) {
    XCTAssertNil(
        root.findEntity(named: name),
        "entity \"\(name)\" unexpectedly present in subtree of \(root.name)",
        file: file, line: line
    )
}
