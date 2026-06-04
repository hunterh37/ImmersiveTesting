import XCTest
import RealityKit
import ImmersiveTestingRuntime

/// Asserts an entity carries a component of the given type.
@MainActor
public func XCTAssertHasComponent<C: Component>(
    _ entity: Entity, _ type: C.Type,
    file: StaticString = #filePath, line: UInt = #line
) {
    XCTAssertNotNil(
        entity.components[type],
        "\(entity.name.isEmpty ? "entity" : entity.name) missing \(type)",
        file: file, line: line
    )
}

/// Asserts an entity does NOT carry a component of the given type.
@MainActor
public func XCTAssertNoComponent<C: Component>(
    _ entity: Entity, _ type: C.Type,
    file: StaticString = #filePath, line: UInt = #line
) {
    XCTAssertNil(
        entity.components[type],
        "\(entity.name.isEmpty ? "entity" : entity.name) unexpectedly has \(type)",
        file: file, line: line
    )
}

/// Asserts an entity has a component of the given type satisfying a predicate.
@MainActor
public func XCTAssertComponent<C: Component>(
    _ entity: Entity, _ type: C.Type,
    satisfies predicate: (C) -> Bool,
    _ message: String = "",
    file: StaticString = #filePath, line: UInt = #line
) {
    guard let c = entity.components[type] else {
        XCTFail("\(entity.name) missing \(type)", file: file, line: line)
        return
    }
    XCTAssertTrue(
        predicate(c),
        message.isEmpty ? "\(type) on \(entity.name) failed predicate" : message,
        file: file, line: line
    )
}

/// Asserts a count of entities in a subtree carry a given component.
@MainActor
public func XCTAssertComponentCount<C: Component>(
    _ root: Entity, _ type: C.Type,
    equals expected: Int,
    file: StaticString = #filePath, line: UInt = #line
) {
    let actual = root.entities(with: type).count
    XCTAssertEqual(actual, expected, "\(type) count", file: file, line: line)
}
