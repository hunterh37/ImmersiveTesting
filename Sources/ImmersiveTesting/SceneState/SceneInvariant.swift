import XCTest
import RealityKit
import ImmersiveTestingRuntime

// MARK: - SceneInvariant

/// A named condition that must hold on every frame of simulation.
///
/// Invariants express *universal* truths about your scene that should never break,
/// regardless of game state. Run them during `SystemHarness.tick(invariants:)` to
/// catch the exact frame a property is violated.
///
/// ```swift
/// SceneInvariant("no NaN transforms") { root in
///     root.allEntities.allSatisfy { $0.worldPosition.isFinite }
/// }
/// ```
public struct SceneInvariant: @unchecked Sendable {
    public let name: String
    let check: @MainActor (Entity) -> Bool

    public init(_ name: String, _ check: @MainActor @escaping (Entity) -> Bool) {
        self.name = name
        self.check = check
    }
}

// MARK: - SceneInvariantSet

/// A collection of `SceneInvariant`s checked as a unit, typically on every simulated frame.
///
/// Build one with a result builder, then pass to `SystemHarness.tick(invariants:)` or call
/// `check(_:frame:)` manually after each state transition in your tests.
///
/// ```swift
/// let invariants = SceneInvariantSet {
///     SceneInvariant("no NaN transforms") { root in
///         root.allEntities.allSatisfy { $0.worldPosition.isFinite }
///     }
///     SceneInvariant("projectile cap ≤ 50") { root in
///         root.entities(with: ProjectileComponent.self).count <= 50
///     }
///     SceneInvariant("player never below floor") { root in
///         (root.findEntity(named: "player")?.worldPosition.y ?? 0) > -0.1
///     }
/// }
///
/// harness.tick(frames: 300, invariants: invariants)
/// ```
@MainActor
public struct SceneInvariantSet {

    private let invariants: [SceneInvariant]

    public init(@InvariantBuilder _ content: () -> [SceneInvariant]) {
        self.invariants = content()
    }

    // MARK: - Checking

    /// Evaluates all invariants against `root`. Fails the current test for each violation,
    /// including the frame number for easier debugging in long simulations.
    public func check(
        _ root: Entity,
        frame: Int = -1,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        for inv in invariants {
            if !inv.check(root) {
                let frameTag = frame >= 0 ? " (frame \(frame))" : ""
                XCTFail("SceneInvariant '\(inv.name)' violated\(frameTag)", file: file, line: line)
            }
        }
    }

    /// Returns the names of all failing invariants without failing the test.
    public func violations(in root: Entity) -> [String] {
        invariants.filter { !$0.check(root) }.map(\.name)
    }
}

// MARK: - Result builder

@resultBuilder
public enum InvariantBuilder {
    public static func buildBlock(_ items: [SceneInvariant]...) -> [SceneInvariant] { items.flatMap { $0 } }
    public static func buildArray(_ items: [[SceneInvariant]]) -> [SceneInvariant] { items.flatMap { $0 } }
    public static func buildOptional(_ item: [SceneInvariant]?) -> [SceneInvariant] { item ?? [] }
    public static func buildEither(first: [SceneInvariant]) -> [SceneInvariant] { first }
    public static func buildEither(second: [SceneInvariant]) -> [SceneInvariant] { second }
    public static func buildExpression(_ e: SceneInvariant) -> [SceneInvariant] { [e] }
}

// MARK: - Common canned invariants

extension SceneInvariant {

    /// No entity in the tree has a NaN or Inf translation.
    @MainActor public static let noNaNTransforms = SceneInvariant("no NaN/Inf transforms") { root in
        root.allEntities.allSatisfy { $0.worldPosition.isFinite }
    }

    /// The named entity must always exist in the scene.
    public static func alwaysPresent(named name: String) -> SceneInvariant {
        SceneInvariant("'\(name)' always present") { root in
            root.findEntity(named: name) != nil
        }
    }

    /// The named entity must never appear in the scene.
    public static func neverPresent(named name: String) -> SceneInvariant {
        SceneInvariant("'\(name)' never present") { root in
            root.findEntity(named: name) == nil
        }
    }

    /// The count of entities matching a component type must stay at or below `limit`.
    public static func cap<C: Component>(_ type: C.Type, atMost limit: Int) -> SceneInvariant {
        SceneInvariant("\(type) count ≤ \(limit)") { root in
            root.entities(with: type).count <= limit
        }
    }
}
