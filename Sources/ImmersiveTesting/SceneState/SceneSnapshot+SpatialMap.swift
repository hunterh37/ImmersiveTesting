import RealityKit
import simd

// MARK: - SpatialMapSymbols

/// Maps entity names to single-character display symbols for ASCII spatial maps.
///
/// ```swift
/// var symbols = SpatialMapSymbols()
/// symbols["player"]   = "@"
/// symbols["zombie_0"] = "Z"
/// symbols["zombie_1"] = "Z"
/// symbols["gun"]      = "G"
/// ```
public struct SpatialMapSymbols {
    var table: [String: Character] = [:]
    public init() {}
    public subscript(name: String) -> Character? {
        get { table[name] }
        set { table[name] = newValue }
    }

    /// Registers all entity names matching a prefix with the same symbol.
    /// Useful for `zombie_0`, `zombie_1`, … → `"Z"`.
    public mutating func register(prefix: String, symbol: Character) {
        for (k, _) in table where k.hasPrefix(prefix) { table[k] = symbol }
    }
}

// MARK: - SpatialMap output

/// A rendered ASCII spatial map and the metadata needed to interpret it.
public struct SpatialMap {
    /// The rendered grid, one line per row.
    public let lines: [String]
    /// Full map as a single newline-separated string.
    public var text: String { lines.joined(separator: "\n") }
    /// World-space origin of the map centre.
    public let center: SIMD3<Float>
    /// Half-extent covered by the map (metres).
    public let range: Float
    /// Number of cells on each axis.
    public let resolution: Int
    /// Entities that fell outside the map bounds (not plotted).
    public let clipped: [String]
}

// MARK: - SceneSnapshot spatial maps

extension SceneSnapshot {

    // MARK: Top-down (X / Z plane)

    /// Renders a top-down ASCII grid showing where entities sit in the horizontal plane.
    ///
    /// The camera looks straight down the −Y axis. X increases rightward; Z increases
    /// downward on screen (toward the viewer), which matches the "standing at origin
    /// looking −Z" convention used throughout visionOS/ARKit.
    ///
    /// ```
    /// // Symbols: @ = avatar (reference), Z = npc, G = gun
    /// let map = snap.topDownMap(
    ///     relativeTo: scene["avatar"]!,
    ///     range: 4.0,
    ///     resolution: 9,
    ///     symbols: { s in s["avatar"] = "@"; s["npc_0"] = "Z"; s["gun"] = "G" }
    /// )
    /// print(map.text)
    /// // . . . . . . . . .
    /// // . . Z . . . . . .
    /// // . . . . @ . . G .
    /// // . . . . . Z . . .
    /// // . . . . . . . . .
    /// ```
    ///
    /// - Parameters:
    ///   - reference: The entity to place at the map centre (usually the player/camera).
    ///   - range: Half-extent in metres. The map covers ±range on both axes.
    ///   - resolution: Number of cells on each side (odd numbers keep the centre cell clean).
    ///   - symbols: Closure that populates the symbol table.
    @MainActor
    public func topDownMap(
        relativeTo reference: Entity,
        range: Float = 5.0,
        resolution: Int = 11,
        symbols configure: (inout SpatialMapSymbols) -> Void
    ) -> SpatialMap {
        var syms = SpatialMapSymbols()
        configure(&syms)

        let center = reference.worldPosition
        var grid = Array(repeating: Array(repeating: Character("."), count: resolution), count: resolution)
        var clipped: [String] = []

        for node in allNodes(root) {
            guard let sym = syms[node.name], let pos = node.position else { continue }
            let dx = pos.x - center.x
            let dz = pos.z - center.z
            if let (col, row) = cell(dx: dx, dy: dz, range: range, resolution: resolution) {
                grid[row][col] = sym
            } else {
                clipped.append(node.name)
            }
        }

        let lines = grid.map { row in row.map(String.init).joined(separator: " ") }
        return SpatialMap(lines: lines, center: center, range: range, resolution: resolution, clipped: clipped)
    }

    // MARK: Side view (Z / Y plane — looking from the right)

    /// Renders a side-view ASCII grid showing height (Y) vs. depth (Z).
    ///
    /// Y increases upward on screen; Z increases rightward (depth away from player).
    /// Useful for asserting HUD elements are at eye level, pickups are near the floor,
    /// and enemies are at standing height.
    ///
    /// ```
    /// // H = HUD, @ = avatar, Z = npc (floor level)
    /// // . H . . .    ← eye level (~1.6 m)
    /// // . . . . .
    /// // . @ . Z .    ← standing level (0 m)
    /// // . . . . .
    /// ```
    @MainActor
    public func sideMap(
        relativeTo reference: Entity,
        range: Float = 5.0,
        resolution: Int = 11,
        symbols configure: (inout SpatialMapSymbols) -> Void
    ) -> SpatialMap {
        var syms = SpatialMapSymbols()
        configure(&syms)

        let center = reference.worldPosition
        var grid = Array(repeating: Array(repeating: Character("."), count: resolution), count: resolution)
        var clipped: [String] = []

        for node in allNodes(root) {
            guard let sym = syms[node.name], let pos = node.position else { continue }
            let dz = pos.z - center.z
            let dy = pos.y - center.y
            // Y increases upward → invert row so top of grid = highest Y
            if let (col, row) = cell(dx: dz, dy: -dy, range: range, resolution: resolution) {
                grid[row][col] = sym
            } else {
                clipped.append(node.name)
            }
        }

        let lines = grid.map { row in row.map(String.init).joined(separator: " ") }
        return SpatialMap(lines: lines, center: center, range: range, resolution: resolution, clipped: clipped)
    }

    // MARK: - Helpers

    /// Converts a world-relative offset into a (col, row) grid index, or nil if out of bounds.
    private func cell(dx: Float, dy: Float, range: Float, resolution: Int) -> (Int, Int)? {
        let half = range
        guard abs(dx) <= half, abs(dy) <= half else { return nil }
        let col = Int(((dx + half) / (half * 2)) * Float(resolution - 1) + 0.5)
        let row = Int(((dy + half) / (half * 2)) * Float(resolution - 1) + 0.5)
        let clamped = (
            min(max(col, 0), resolution - 1),
            min(max(row, 0), resolution - 1)
        )
        return clamped
    }

    private func allNodes(_ node: SnapshotNode) -> [SnapshotNode] {
        [node] + node.children.flatMap { allNodes($0) }
    }
}
