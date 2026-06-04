import XCTest
import RealityKit
import ImmersiveTestingRuntime

// MARK: - EntityPredicate

/// A named predicate that matches entities — used in quantified `SceneRequirement`s.
///
/// ```swift
/// EntityPredicate.hasComponent(NPCAIComponent.self)
/// EntityPredicate.named("avatar")
/// EntityPredicate.satisfies("lives > 0") { $0.components[VitalComponent.self]?.lives ?? 0 > 0 }
/// ```
public struct EntityPredicate {
    public let label: String
    let matches: @MainActor (Entity) -> Bool

    public init(label: String, _ matches: @MainActor @escaping (Entity) -> Bool) {
        self.label = label
        self.matches = matches
    }

    /// Matches any entity carrying the given component type.
    public static func hasComponent<C: Component>(_ type: C.Type) -> EntityPredicate {
        EntityPredicate(label: "has \(type)") { $0.components[type] != nil }
    }

    /// Matches entities whose `name` equals `value`.
    public static func named(_ value: String) -> EntityPredicate {
        EntityPredicate(label: "named \"\(value)\"") { $0.name == value }
    }

    /// Matches entities satisfying an arbitrary condition. Provide a `description` for
    /// failure readability.
    public static func satisfies(_ description: String, _ check: @MainActor @escaping (Entity) -> Bool) -> EntityPredicate {
        EntityPredicate(label: description, check)
    }
}

// MARK: - SceneRequirement

/// A single expectation within a `SceneStateSpec`.
///
/// Build via the free functions `Requires(_:)`, `Forbids(_:)`, and `Expect(_:_:)` inside
/// a `SceneStateSpec` result builder body.
public enum SceneRequirement {

    /// The named entity must exist somewhere in the scene graph.
    case entityExists(named: String)

    /// No entity with this name may exist in the scene graph.
    case entityAbsent(named: String)

    /// At least `count` entities in the subtree must match `predicate`.
    case atLeast(Int, EntityPredicate)

    /// Exactly `count` entities in the subtree must match `predicate`.
    case exactly(Int, EntityPredicate)

    /// At most `count` entities in the subtree may match `predicate`.
    case atMost(Int, EntityPredicate)

    /// The named entity must satisfy a custom check. Supply a human-readable
    /// `description` so failures explain *what* was expected.
    case entitySatisfies(named: String, description: String, check: @MainActor (Entity) -> Bool)

    /// An arbitrary whole-scene check. Supply a `description` for failure output.
    case custom(description: String, check: @MainActor (Entity) -> Bool)
}

// MARK: - Builder helpers (free functions)

/// The named entity must exist anywhere in the scene.
public func Requires(entityNamed name: String) -> SceneRequirement {
    .entityExists(named: name)
}

/// No entity with this name may be in the scene.
public func Forbids(entityNamed name: String) -> SceneRequirement {
    .entityAbsent(named: name)
}

/// At least `count` entities matching `predicate` must be in the scene.
public func Requires(atLeast count: Int, matching predicate: EntityPredicate) -> SceneRequirement {
    .atLeast(count, predicate)
}

/// Exactly `count` entities matching `predicate` must be in the scene.
public func Requires(exactly count: Int, matching predicate: EntityPredicate) -> SceneRequirement {
    .exactly(count, predicate)
}

/// At most `count` entities matching `predicate` may be in the scene.
public func Requires(atMost count: Int, matching predicate: EntityPredicate) -> SceneRequirement {
    .atMost(count, predicate)
}

/// The named entity must satisfy `check`. Provide a `description` for failure readability.
public func Expect(
    entityNamed name: String,
    _ description: String = "",
    _ check: @MainActor @escaping (Entity) -> Bool
) -> SceneRequirement {
    .entitySatisfies(named: name, description: description.isEmpty ? name : description, check: check)
}

/// A free-form scene-level assertion with a `description`.
public func Expect(
    _ description: String,
    _ check: @MainActor @escaping (Entity) -> Bool
) -> SceneRequirement {
    .custom(description: description, check: check)
}

// MARK: - Result builder

@resultBuilder
public enum RequirementBuilder {
    public static func buildBlock(_ items: [SceneRequirement]...) -> [SceneRequirement] { items.flatMap { $0 } }
    public static func buildArray(_ items: [[SceneRequirement]]) -> [SceneRequirement] { items.flatMap { $0 } }
    public static func buildOptional(_ item: [SceneRequirement]?) -> [SceneRequirement] { item ?? [] }
    public static func buildEither(first: [SceneRequirement]) -> [SceneRequirement] { first }
    public static func buildEither(second: [SceneRequirement]) -> [SceneRequirement] { second }
    public static func buildExpression(_ e: SceneRequirement) -> [SceneRequirement] { [e] }
}

// MARK: - Violation

/// The outcome of evaluating a single `SceneRequirement`.
public struct SpecViolation {
    public let passed: Bool
    public let description: String
}

// MARK: - SceneStateSpec

/// Declarative, human-readable expectations about what an entity subtree should look like
/// when the game is in a specific state.
///
/// Build a spec once per state, then call `.assert(against:)` after triggering the state
/// transition to verify the scene was configured correctly — without a running headset.
///
/// Rich failure output names every passing and failing requirement, so you immediately know
/// what the scene was missing, not just "assertion failed".
///
/// ```swift
/// let roundActive = SceneStateSpec("roundActive") {
///     Requires(entityNamed: "objectiveAnchor")
///     Requires(atLeast: 1, matching: .hasComponent(NPCAIComponent.self))
///     Requires(exactly: 1, matching: .named("avatar"))
///     Forbids(entityNamed: "mainMenuPanel")
///     Expect(entityNamed: "avatar", "lives == 3") { entity in
///         entity.components[VitalComponent.self]?.lives == 3
///     }
/// }
///
/// viewModel.startRound()
/// roundActive.assert(against: scene.root)
/// ```
///
/// **Failure output:**
/// ```
/// SceneStateSpec "roundActive" failed (2 violations):
///   ✗ requires entity "objectiveAnchor"                — not found
///   ✗ forbids entity "mainMenuPanel"                  — present at /root/ui/mainMenuPanel
///   ✓ at least 1 has NPCAIComponent               — found 3
///   ✓ exactly 1 named "avatar"                        — found 1
///   ✓ avatar: lives == 3
/// ```
@MainActor
public struct SceneStateSpec {

    public let name: String
    private let requirements: [SceneRequirement]

    public init(_ name: String, @RequirementBuilder _ content: () -> [SceneRequirement]) {
        self.name = name
        self.requirements = content()
    }

    // MARK: - Evaluation

    /// Evaluates all requirements against `root` and returns per-requirement results.
    public func evaluate(against root: Entity) -> [SpecViolation] {
        requirements.map { evaluate($0, against: root) }
    }

    private func evaluate(_ req: SceneRequirement, against root: Entity) -> SpecViolation {
        switch req {

        case .entityExists(let name):
            let found = root.findEntity(named: name) != nil
            return SpecViolation(
                passed: found,
                description: found
                    ? "requires entity \"\(name)\" — found"
                    : "requires entity \"\(name)\" — not found"
            )

        case .entityAbsent(let name):
            let entity = root.findEntity(named: name)
            let absent = entity == nil
            let path = entity.map { pathDescription($0, in: root) } ?? ""
            return SpecViolation(
                passed: absent,
                description: absent
                    ? "forbids entity \"\(name)\" — absent ✓"
                    : "forbids entity \"\(name)\" — present\(path.isEmpty ? "" : " at \(path)")"
            )

        case .atLeast(let count, let predicate):
            let found = root.allEntities.filter { predicate.matches($0) }.count
            let passed = found >= count
            return SpecViolation(
                passed: passed,
                description: "at least \(count) \(predicate.label) — found \(found)"
            )

        case .exactly(let count, let predicate):
            let found = root.allEntities.filter { predicate.matches($0) }.count
            let passed = found == count
            return SpecViolation(
                passed: passed,
                description: "exactly \(count) \(predicate.label) — found \(found)"
            )

        case .atMost(let count, let predicate):
            let found = root.allEntities.filter { predicate.matches($0) }.count
            let passed = found <= count
            return SpecViolation(
                passed: passed,
                description: "at most \(count) \(predicate.label) — found \(found)"
            )

        case .entitySatisfies(let name, let description, let check):
            guard let entity = root.findEntity(named: name) else {
                return SpecViolation(
                    passed: false,
                    description: "\(description) — entity \"\(name)\" not found"
                )
            }
            let passed = check(entity)
            return SpecViolation(
                passed: passed,
                description: "\(description) — \(passed ? "✓" : "✗")"
            )

        case .custom(let description, let check):
            let passed = check(root)
            return SpecViolation(
                passed: passed,
                description: "\(description) — \(passed ? "✓" : "✗")"
            )
        }
    }

    // MARK: - XCTest integration

    /// Asserts all requirements pass. Emits a single aggregated failure message listing
    /// every requirement with ✓/✗ symbols, so one test call surfaces the complete picture.
    public func assert(
        against root: Entity,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let results = evaluate(against: root)
        let failures = results.filter { !$0.passed }
        guard !failures.isEmpty else { return }

        let lines = results.map { "  \($0.passed ? "✓" : "✗") \($0.description)" }.joined(separator: "\n")
        XCTFail(
            "SceneStateSpec \"\(name)\" failed (\(failures.count) violation\(failures.count == 1 ? "" : "s")):\n\(lines)",
            file: file, line: line
        )
    }

    /// Returns violation descriptions without failing the test — useful for conditional logic.
    public func violations(against root: Entity) -> [String] {
        evaluate(against: root).filter { !$0.passed }.map(\.description)
    }

    // MARK: - Path helper

    private func pathDescription(_ target: Entity, in root: Entity) -> String {
        var path = [target.name]
        var current = target.parent
        while let p = current, p !== root {
            path.insert(p.name, at: 0)
            current = p.parent
        }
        path.insert(root.name, at: 0)
        return "/" + path.joined(separator: "/")
    }
}
