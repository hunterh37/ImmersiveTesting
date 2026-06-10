import RealityKit
import ImmersiveTestingRuntime
import XCTest
import simd

// MARK: - SnapshotOptions

/// Controls what detail is captured by `SceneSnapshot`.
public struct SnapshotOptions: Sendable {
    /// Include world-space position in the output.
    public var includePositions: Bool
    /// Include collision group raw values when a `CollisionComponent` is present.
    public var includeCollisionGroups: Bool
    /// Maximum subtree depth to capture (nil = unlimited).
    public var maxDepth: Int?

    public init(
        includePositions: Bool = true,
        includeCollisionGroups: Bool = true,
        maxDepth: Int? = nil
    ) {
        self.includePositions = includePositions
        self.includeCollisionGroups = includeCollisionGroups
        self.maxDepth = maxDepth
    }

    public static let `default` = SnapshotOptions()
    public static let shallow   = SnapshotOptions(maxDepth: 2)
    public static let namesOnly = SnapshotOptions(includePositions: false, includeCollisionGroups: false)
}

// MARK: - SnapshotNode

/// One node in a captured entity tree.
public struct SnapshotNode: Equatable {
    public let name: String
    public let position: SIMD3<Float>?
    public let collisionGroup: UInt32?
    public let children: [SnapshotNode]

    public init(name: String, position: SIMD3<Float>?, collisionGroup: UInt32?, children: [SnapshotNode]) {
        self.name = name
        self.position = position
        self.collisionGroup = collisionGroup
        self.children = children
    }
}

// MARK: - SceneSnapshot

/// A structural snapshot of an entity subtree — names, positions, collision groups, and
/// the parent-child hierarchy, captured into a value type for diffing and golden-file tests.
///
/// Unlike pixel snapshots, `SceneSnapshot` is **deterministic and CI-stable** because it
/// captures configuration, not rendering.
///
/// ```swift
/// let snap = SceneSnapshot(scene.root)
/// print(snap.tree)
/// /*
///  root
///  ├─ head
///  │  └─ pointer  pos(0.10, -0.10, -0.20)
///  │     └─ pointerTip  pos(0.00, 0.00, -0.15)
///  └─ npc  pos(0.00, 0.00, -3.00)  group:8192
/// */
///
/// // Golden-file style: record on first run, assert on subsequent runs.
/// let baseline = SceneSnapshot(scene.root)
/// // … mutate scene …
/// let current  = SceneSnapshot(scene.root)
/// XCTAssertSnapshotsMatch(current, baseline: baseline)
/// ```
@MainActor
public struct SceneSnapshot {

    public let root: SnapshotNode
    public let options: SnapshotOptions

    public init(_ entity: Entity, options: SnapshotOptions = .default) {
        self.options = options
        self.root = SceneSnapshot.capture(entity, depth: 0, options: options)
    }

    // MARK: - Capture

    private static func capture(_ entity: Entity, depth: Int, options: SnapshotOptions) -> SnapshotNode {
        let pos: SIMD3<Float>? = options.includePositions ? entity.worldPosition : nil
        let group: UInt32? = options.includeCollisionGroups
            ? entity.components[CollisionComponent.self]?.filter.group.rawValue
            : nil

        let childNodes: [SnapshotNode]
        if let maxDepth = options.maxDepth, depth >= maxDepth {
            childNodes = []
        } else {
            childNodes = entity.children.map { capture($0, depth: depth + 1, options: options) }
        }

        return SnapshotNode(name: entity.name, position: pos, collisionGroup: group, children: childNodes)
    }

    // MARK: - Tree dump

    /// A human-readable ASCII tree of the snapshot — useful for debugging, print, PR review.
    public var tree: String {
        var lines: [String] = []
        appendLines(root, prefix: "", isLast: true, isRoot: true, lines: &lines)
        return lines.joined(separator: "\n")
    }

    private func appendLines(
        _ node: SnapshotNode,
        prefix: String,
        isLast: Bool,
        isRoot: Bool,
        lines: inout [String]
    ) {
        let connector = isRoot ? "" : (isLast ? "└─ " : "├─ ")
        var detail = ""
        if let p = node.position {
            detail += "  pos(\(fmt(p.x)), \(fmt(p.y)), \(fmt(p.z)))"
        }
        if let g = node.collisionGroup {
            detail += "  group:\(g)"
        }
        lines.append("\(prefix)\(connector)\(node.name)\(detail)")

        let childPrefix = isRoot ? "" : prefix + (isLast ? "   " : "│  ")
        for (i, child) in node.children.enumerated() {
            appendLines(child, prefix: childPrefix, isLast: i == node.children.count - 1, isRoot: false, lines: &lines)
        }
    }

    private func fmt(_ v: Float) -> String { String(format: "%.2f", v) }

    // MARK: - Diff

    /// Returns a human-readable diff string, or nil if the snapshots are identical.
    public func diff(from baseline: SceneSnapshot) -> String? {
        var changes: [String] = []
        diffNodes(root, baseline: baseline.root, path: "/\(root.name)", changes: &changes)
        guard !changes.isEmpty else { return nil }
        return changes.joined(separator: "\n")
    }

    private func diffNodes(_ current: SnapshotNode, baseline: SnapshotNode, path: String, changes: inout [String]) {
        if current.name != baseline.name {
            changes.append("  ~ \(path): name changed \"\(baseline.name)\" → \"\(current.name)\"")
        }
        if let cp = current.position, let bp = baseline.position {
            let d = simd_distance(cp, bp)
            if d > 0.001 {
                changes.append("  ~ \(path): position moved \(String(format: "%.3f", d))m")
            }
        }
        if current.collisionGroup != baseline.collisionGroup {
            changes.append("  ~ \(path): collisionGroup \(baseline.collisionGroup.map(String.init) ?? "nil") → \(current.collisionGroup.map(String.init) ?? "nil")")
        }

        // Pair children by name in order, treating same-named siblings as a multiset so
        // duplicate names (e.g. two "hitbox" colliders) are diffed and counted correctly
        // rather than collapsed into a single Set entry.
        var baselineByName: [String: [SnapshotNode]] = [:]
        for child in baseline.children { baselineByName[child.name, default: []].append(child) }

        for currentChild in current.children {
            guard var pool = baselineByName[currentChild.name], !pool.isEmpty else {
                // No remaining baseline sibling with this name to pair with → added.
                changes.append("  + \(path)/\(currentChild.name): added")
                continue
            }
            let baselineChild = pool.removeFirst()
            baselineByName[currentChild.name] = pool
            diffNodes(currentChild, baseline: baselineChild, path: "\(path)/\(currentChild.name)", changes: &changes)
        }

        // Any baseline children left unpaired were removed.
        for leftovers in baselineByName.values {
            for removed in leftovers {
                changes.append("  - \(path)/\(removed.name): removed")
            }
        }
    }

    // MARK: - Entity count

    /// Total number of nodes captured (including root).
    public var entityCount: Int { count(root) }
    private func count(_ node: SnapshotNode) -> Int { 1 + node.children.reduce(0) { $0 + count($1) } }
}

// MARK: - XCTest assertion

/// Asserts two `SceneSnapshot`s are structurally identical. On failure, prints a
/// human-readable diff listing added, removed, and mutated nodes.
@MainActor
public func XCTAssertSnapshotsMatch(
    _ current: SceneSnapshot,
    baseline: SceneSnapshot,
    _ message: String = "",
    file: StaticString = #filePath,
    line: UInt = #line
) {
    guard let diff = current.diff(from: baseline) else { return }
    let header = message.isEmpty ? "SceneSnapshot mismatch:" : "\(message):\nSceneSnapshot mismatch:"
    XCTFail("\(header)\n\(diff)", file: file, line: line)
}
