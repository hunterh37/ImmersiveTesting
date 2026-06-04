import RealityKit
import simd

/// A headless entity graph for tests. Wraps a real RealityKit `Entity` root — everything
/// built here is exactly what RealityKit would hold at runtime.
@MainActor
public final class TestScene {
    public let root: Entity

    public init(rootName: String = "root", @EntityBuilder _ content: () -> [Entity]) {
        let r = Entity()
        r.name = rootName
        for child in content() { r.addChild(child) }
        self.root = r
    }

    /// Adopts an already-built entity graph as the scene root. Use this to wrap the output
    /// of a real `SceneBuilder` (the production graph builder) so the same assertions run
    /// against the actual scene the app produces — not a hand-copied stand-in.
    public init(adopting root: Entity) {
        self.root = root
    }

    /// Look up an entity by exact name, or by dotted path (`"pointer.pointerTip"`).
    ///
    /// An exact full-name match wins first, so entities whose own name contains a `.`
    /// (e.g. `"npc_0.head"`) are found directly. Only if no entity has that exact name
    /// is the string treated as a dotted path walked child-by-child from the root.
    public subscript(path: String) -> Entity? {
        // 1. Exact name match anywhere in the subtree (handles names containing ".").
        if root.name == path { return root }
        if let exact = root.findEntity(named: path) { return exact }
        // 2. Fall back to a dotted path walked through child names.
        return entity(atPath: path)
    }

    /// Resolves a dotted path (`"pointer.pointerTip"`) strictly by walking child names from the
    /// root, ignoring exact-name matches. Use when a path segment could otherwise collide
    /// with a literal dotted name elsewhere in the graph.
    public func entity(atPath path: String) -> Entity? {
        let parts = path.split(separator: ".").map(String.init)
        guard let first = parts.first else { return nil }
        // First segment is resolved anywhere in the subtree; later segments are walked
        // strictly through child names.
        var current: Entity? = (root.name == first) ? root : root.findEntity(named: first)
        for part in parts.dropFirst() {
            current = current?.children.first { $0.name == part }
        }
        return current
    }
}

@resultBuilder
public enum EntityBuilder {
    public static func buildBlock(_ components: [Entity]...) -> [Entity] { components.flatMap { $0 } }
    public static func buildArray(_ components: [[Entity]]) -> [Entity] { components.flatMap { $0 } }
    public static func buildOptional(_ component: [Entity]?) -> [Entity] { component ?? [] }
    public static func buildEither(first component: [Entity]) -> [Entity] { component }
    public static func buildEither(second component: [Entity]) -> [Entity] { component }
    public static func buildExpression(_ expression: Entity) -> [Entity] { [expression] }
}

// MARK: - Fluent entity construction

@MainActor
extension Entity {
    /// Names an entity inline. `Entity("pointer")`.
    public convenience init(_ name: String) {
        self.init()
        self.name = name
    }

    @discardableResult
    public func position(_ x: Float, _ y: Float, _ z: Float) -> Self {
        self.position = SIMD3(x, y, z); return self
    }

    @discardableResult
    public func position(_ p: SIMD3<Float>) -> Self {
        self.position = p; return self
    }

    @discardableResult
    public func component<C: Component>(_ c: C) -> Self {
        components.set(c); return self
    }

    /// Attaches a `CollisionComponent` with a single placeholder shape and the given filter.
    @discardableResult
    public func collider(group: CollisionGroup, mask: CollisionGroup) -> Self {
        let shape = ShapeResource.generateBox(size: [0.1, 0.1, 0.1])
        var collision = CollisionComponent(shapes: [shape])
        collision.filter = CollisionFilter(group: group, mask: mask)
        components.set(collision)
        return self
    }

    @discardableResult
    public func children(@EntityBuilder _ content: () -> [Entity]) -> Self {
        for child in content() { addChild(child) }
        return self
    }
}
