import XCTest
import RealityKit
import simd

// MARK: - SpatialExpectation

/// A single spatial relationship between entities in a `SpatialLayoutSpec`.
public enum SpatialExpectation {

    /// Entity is within `distance` metres of the reference entity's position.
    case withinReach(named: String, within: Float)

    /// Entity's world Y is between `min` and `max` metres.
    case atHeight(named: String, min: Float, max: Float)

    /// Entity is in the forward hemisphere of `reference` (dot product with forward > 0)
    /// and within `distance` metres. Pass `nil` distance to skip the distance check.
    case inFrontOf(named: String, within: Float?)

    /// Entity is in the rearward hemisphere of `reference`.
    case behind(named: String, within: Float?)

    /// Entity is to the left hemisphere of `reference`.
    case toTheLeft(named: String, within: Float?)

    /// Entity is to the right hemisphere of `reference`.
    case toTheRight(named: String, within: Float?)

    /// `upper` entity's world Y is strictly greater than `lower` entity's world Y.
    case above(String, _ lower: String)

    /// `entity` Y is within `tolerance` metres of `eyeHeight` (default 1.6 m for a standing user).
    case atEyeLevel(named: String, eyeHeight: Float, tolerance: Float)

    /// Entity's distance to the reference is at least `minimum` metres (not too close).
    case noCloserThan(named: String, minimum: Float)

    /// Entity is within `tolerance` metres of the reference's height — same elevation.
    case sameElevationAs(named: String, tolerance: Float)
}

// MARK: - Result builder

@resultBuilder
public enum SpatialExpectationBuilder {
    public static func buildBlock(_ items: [SpatialExpectation]...) -> [SpatialExpectation] { items.flatMap { $0 } }
    public static func buildArray(_ items: [[SpatialExpectation]]) -> [SpatialExpectation] { items.flatMap { $0 } }
    public static func buildOptional(_ item: [SpatialExpectation]?) -> [SpatialExpectation] { item ?? [] }
    public static func buildEither(first: [SpatialExpectation]) -> [SpatialExpectation] { first }
    public static func buildEither(second: [SpatialExpectation]) -> [SpatialExpectation] { second }
    public static func buildExpression(_ e: SpatialExpectation) -> [SpatialExpectation] { [e] }
}

// MARK: - SpatialLayoutSpec

/// Declarative assertions about how entities are spatially arranged relative to a reference
/// point (typically the player/camera entity).
///
/// Catches the class of bugs invisible to component/hierarchy assertions: a zombie that
/// spawned behind the player, a gun at floor level, a HUD floating to the side, a pickup
/// placed out of reach.
///
/// > **Tip:** Swift's implicit member syntax (`.xxx`) works fine for 1–3 expectations per
/// > spec. For 4+ expectations in one block, prefix explicitly with `SpatialExpectation.xxx`
/// > to avoid a type-inference compile error. Splitting into smaller specs also works.
///
/// ```swift
/// SpatialLayoutSpec("weapon-in-hand", relativeTo: scene["avatar"]!) {
///     SpatialExpectation.inFrontOf(named: "gun", within: 0.6)
///     SpatialExpectation.atHeight(named: "gun", min: 0.9, max: 1.7)
///     .withinReach(named: "gun", within: 0.8)
/// }
/// .assert(against: scene.root)
///
/// SpatialLayoutSpec("round-started", relativeTo: scene["avatar"]!) {
///     .atEyeLevel(named: "hud", eyeHeight: 1.6, tolerance: 0.3)
///     .inFrontOf(named: "npc_0", within: 5.0)
///     .noCloserThan(named: "npc_0", minimum: 1.5)
///     .above("head_hitbox", "torso_hitbox")
/// }
/// .assert(against: scene.root)
/// ```
///
/// **Failure output:**
/// ```
/// SpatialLayoutSpec "weapon-in-hand" failed (1 violation):
///   ✗ gun: atHeight(min:0.90, max:1.70)   — y=0.12 (out of range)
///   ✓ gun: inFrontOf(within:0.60)         — dist=0.35, dot=0.92
///   ✓ gun: withinReach(0.80)              — dist=0.35
/// ```
@MainActor
public struct SpatialLayoutSpec {

    public let name: String
    private let reference: Entity
    private let expectations: [SpatialExpectation]

    public init(
        _ name: String,
        relativeTo reference: Entity,
        @SpatialExpectationBuilder _ content: () -> [SpatialExpectation]
    ) {
        self.name = name
        self.reference = reference
        self.expectations = content()
    }

    // MARK: - Violation result

    public struct Violation {
        public let passed: Bool
        public let description: String
    }

    // MARK: - Evaluation

    public func evaluate(against root: Entity) -> [Violation] {
        expectations.map { evaluate($0, root: root) }
    }

    private func evaluate(_ exp: SpatialExpectation, root: Entity) -> Violation {
        let refPos = reference.worldPosition
        let refFwd = reference.worldForward

        switch exp {

        case .withinReach(let name, let maxDist):
            guard let e = root.findEntity(named: name) else {
                return Violation(passed: false, description: "\(name): withinReach(\(fmt(maxDist)))       — entity not found")
            }
            let d = simd_distance(e.worldPosition, refPos)
            let ok = d <= maxDist
            return Violation(
                passed: ok,
                description: "\(name): withinReach(\(fmt(maxDist)))       — dist=\(fmt(d))\(ok ? "" : " (too far)")"
            )

        case .atHeight(let name, let minY, let maxY):
            guard let e = root.findEntity(named: name) else {
                return Violation(passed: false, description: "\(name): atHeight(min:\(fmt(minY)), max:\(fmt(maxY)))  — entity not found")
            }
            let y = e.worldPosition.y
            let ok = y >= minY && y <= maxY
            return Violation(
                passed: ok,
                description: "\(name): atHeight(min:\(fmt(minY)), max:\(fmt(maxY)))  — y=\(fmt(y))\(ok ? "" : " (out of range)")"
            )

        case .inFrontOf(let name, let maxDist):
            guard let e = root.findEntity(named: name) else {
                return Violation(passed: false, description: "\(name): inFrontOf\(maxDist.map { "(within:\(fmt($0)))" } ?? "")  — entity not found")
            }
            let toEntity = simd_normalize(e.worldPosition - refPos)
            let dot = simd_dot(refFwd, toEntity)
            let d = simd_distance(e.worldPosition, refPos)
            let inFront = dot > 0
            let inRange = maxDist.map { d <= $0 } ?? true
            let ok = inFront && inRange
            let distLabel = maxDist.map { ", within:\(fmt($0))" } ?? ""
            return Violation(
                passed: ok,
                description: "\(name): inFrontOf\(distLabel)       — dist=\(fmt(d)), dot=\(fmt(dot))\(ok ? "" : " (\(!inFront ? "behind reference" : "too far"))")"
            )

        case .behind(let name, let maxDist):
            guard let e = root.findEntity(named: name) else {
                return Violation(passed: false, description: "\(name): behind  — entity not found")
            }
            let toEntity = simd_normalize(e.worldPosition - refPos)
            let dot = simd_dot(refFwd, toEntity)
            let d = simd_distance(e.worldPosition, refPos)
            let isBehind = dot < 0
            let inRange = maxDist.map { d <= $0 } ?? true
            let ok = isBehind && inRange
            return Violation(
                passed: ok,
                description: "\(name): behind       — dist=\(fmt(d)), dot=\(fmt(dot))\(ok ? "" : " (in front of reference)")"
            )

        case .toTheLeft(let name, let maxDist):
            guard let e = root.findEntity(named: name) else {
                return Violation(passed: false, description: "\(name): toTheLeft  — entity not found")
            }
            let right = simd_normalize(simd_cross(refFwd, reference.worldUp))
            let toEntity = e.worldPosition - refPos
            let d = simd_distance(e.worldPosition, refPos)
            let dotRight = simd_dot(right, simd_normalize(toEntity))
            let inRange = maxDist.map { d <= $0 } ?? true
            let ok = dotRight < 0 && inRange
            return Violation(
                passed: ok,
                description: "\(name): toTheLeft    — dist=\(fmt(d)), dotRight=\(fmt(dotRight))\(ok ? "" : " (not to the left)")"
            )

        case .toTheRight(let name, let maxDist):
            guard let e = root.findEntity(named: name) else {
                return Violation(passed: false, description: "\(name): toTheRight  — entity not found")
            }
            let right = simd_normalize(simd_cross(refFwd, reference.worldUp))
            let toEntity = e.worldPosition - refPos
            let d = simd_distance(e.worldPosition, refPos)
            let dotRight = simd_dot(right, simd_normalize(toEntity))
            let inRange = maxDist.map { d <= $0 } ?? true
            let ok = dotRight > 0 && inRange
            return Violation(
                passed: ok,
                description: "\(name): toTheRight   — dist=\(fmt(d)), dotRight=\(fmt(dotRight))\(ok ? "" : " (not to the right)")"
            )

        case .above(let upper, let lower):
            guard let eu = root.findEntity(named: upper) else {
                return Violation(passed: false, description: "\(upper) above \(lower)  — '\(upper)' not found")
            }
            guard let el = root.findEntity(named: lower) else {
                return Violation(passed: false, description: "\(upper) above \(lower)  — '\(lower)' not found")
            }
            let uy = eu.worldPosition.y
            let ly = el.worldPosition.y
            let ok = uy > ly
            return Violation(
                passed: ok,
                description: "\(upper) above \(lower)  — \(fmt(uy)) vs \(fmt(ly))\(ok ? "" : " (\(upper) is not higher)")"
            )

        case .atEyeLevel(let name, let eyeH, let tol):
            guard let e = root.findEntity(named: name) else {
                return Violation(passed: false, description: "\(name): atEyeLevel(\(fmt(eyeH))±\(fmt(tol)))  — entity not found")
            }
            let y = e.worldPosition.y
            let ok = abs(y - eyeH) <= tol
            return Violation(
                passed: ok,
                description: "\(name): atEyeLevel(\(fmt(eyeH))±\(fmt(tol)))  — y=\(fmt(y))\(ok ? "" : " (off by \(fmt(abs(y - eyeH)))m)")"
            )

        case .noCloserThan(let name, let minDist):
            guard let e = root.findEntity(named: name) else {
                return Violation(passed: false, description: "\(name): noCloserThan(\(fmt(minDist)))  — entity not found")
            }
            let d = simd_distance(e.worldPosition, refPos)
            let ok = d >= minDist
            return Violation(
                passed: ok,
                description: "\(name): noCloserThan(\(fmt(minDist)))  — dist=\(fmt(d))\(ok ? "" : " (too close)")"
            )

        case .sameElevationAs(let name, let tol):
            guard let e = root.findEntity(named: name) else {
                return Violation(passed: false, description: "\(name): sameElevationAs(ref, ±\(fmt(tol)))  — entity not found")
            }
            let diff = abs(e.worldPosition.y - refPos.y)
            let ok = diff <= tol
            return Violation(
                passed: ok,
                description: "\(name): sameElevationAs(ref, ±\(fmt(tol)))  — Δy=\(fmt(diff))\(ok ? "" : " (elevation mismatch)")"
            )
        }
    }

    // MARK: - XCTest integration

    /// Asserts all spatial expectations pass. Emits a single aggregated failure with ✓/✗
    /// per expectation, so you see the full picture in one test failure.
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
            "SpatialLayoutSpec \"\(name)\" failed (\(failures.count) violation\(failures.count == 1 ? "" : "s")):\n\(lines)",
            file: file, line: line
        )
    }

    /// Returns violation descriptions without failing the test.
    public func violations(against root: Entity) -> [String] {
        evaluate(against: root).filter { !$0.passed }.map(\.description)
    }

    // MARK: - Formatting

    private func fmt(_ v: Float) -> String { String(format: "%.2f", v) }
    private func fmt(_ v: Float?) -> String { v.map { String(format: "%.2f", $0) } ?? "∞" }
}

// MARK: - XCTest integration for ASCII maps

/// Asserts the top-down ASCII map of a snapshot matches the expected pattern string.
/// Use `"_"` as a wildcard cell that matches any character.
///
/// ```swift
/// let snap = SceneSnapshot(scene.root)
/// XCTAssertTopDownMap(
///     snap,
///     relativeTo: scene["avatar"]!,
///     range: 3.0, resolution: 5,
///     symbols: { $0["avatar"] = "@"; $0["npc_0"] = "N" },
///     matches: """
///     . . . . .
///     . . N . .
///     . . . @ .
///     . . . . .
///     . . . . .
///     """
/// )
/// ```
@MainActor
public func XCTAssertTopDownMap(
    _ snapshot: SceneSnapshot,
    relativeTo reference: Entity,
    range: Float = 5.0,
    resolution: Int = 11,
    symbols configure: (inout SpatialMapSymbols) -> Void,
    matches expected: String,
    _ message: String = "",
    file: StaticString = #filePath,
    line: UInt = #line
) {
    let map = snapshot.topDownMap(relativeTo: reference, range: range, resolution: resolution, symbols: configure)
    assertMapsMatch(actual: map.lines, expected: expected, name: "top-down", message: message, file: file, line: line)
}

/// Asserts the side-view (Z/Y) ASCII map matches the expected pattern string.
/// Use `"_"` as a wildcard cell.
@MainActor
public func XCTAssertSideMap(
    _ snapshot: SceneSnapshot,
    relativeTo reference: Entity,
    range: Float = 5.0,
    resolution: Int = 11,
    symbols configure: (inout SpatialMapSymbols) -> Void,
    matches expected: String,
    _ message: String = "",
    file: StaticString = #filePath,
    line: UInt = #line
) {
    let map = snapshot.sideMap(relativeTo: reference, range: range, resolution: resolution, symbols: configure)
    assertMapsMatch(actual: map.lines, expected: expected, name: "side", message: message, file: file, line: line)
}

// MARK: - Internal map comparison

private func assertMapsMatch(
    actual: [String],
    expected: String,
    name: String,
    message: String,
    file: StaticString,
    line: UInt
) {
    let expectedLines = expected.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }

    guard actual.count == expectedLines.count else {
        XCTFail(
            "\(message.isEmpty ? "" : "\(message)\n")\(name) map row count mismatch: actual \(actual.count) vs expected \(expectedLines.count)",
            file: file, line: line
        )
        return
    }

    var mismatches: [(Int, String, String)] = []
    for (i, (aLine, eLine)) in zip(actual, expectedLines).enumerated() {
        let aCells = aLine.split(separator: " ").map(String.init)
        let eCells = eLine.split(separator: " ").map(String.init)
        guard aCells.count == eCells.count else {
            mismatches.append((i, aLine, eLine)); continue
        }
        for (a, e) in zip(aCells, eCells) {
            if e != "_" && a != e { mismatches.append((i, aLine, eLine)); break }
        }
    }

    guard !mismatches.isEmpty else { return }

    var report = "\(message.isEmpty ? "" : "\(message)\n")\(name) map mismatch on \(mismatches.count) row(s):\n"
    report += "Actual:\n" + actual.map { "  \($0)" }.joined(separator: "\n")
    report += "\nExpected:\n" + expectedLines.map { "  \($0)" }.joined(separator: "\n")
    report += "\nMismatched rows:"
    for (i, a, e) in mismatches { report += "\n  row \(i): got [\(a)] expected [\(e)]" }
    XCTFail(report, file: file, line: line)
}
