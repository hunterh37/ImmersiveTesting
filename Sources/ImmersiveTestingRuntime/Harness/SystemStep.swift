import RealityKit

// MARK: - SystemStep

/// A named, closure-based simulation step — the testable stand-in for a RealityKit `System`.
///
/// `SceneUpdateContext` has no public initializer — RealityKit constructs it internally.
/// You cannot call `System.update(context:)` directly from a test on any platform. Instead,
/// extract your system's core logic into a static method and register that here.
///
/// **Blessed pattern** — put the heavy lifting in a static method your `System` delegates to:
/// ```swift
/// // In your app:
/// struct MotionSystem: System {
///     func update(context: SceneUpdateContext) {
///         MotionSystem.step(entities: context.entities.compactMap { $0 }, dt: Float(context.deltaTime))
///     }
///     static func step(entities: [Entity], dt: Float) {
///         for e in entities where e.components[VelocityComponent.self] != nil {
///             e.position += e.components[VelocityComponent.self]!.value * dt
///         }
///     }
/// }
///
/// // In your test:
/// harness.registerStep("motion") { entities, dt in
///     MotionSystem.step(entities: entities, dt: dt)
/// }
/// ```
public struct SystemStep {
    public let name: String
    public let body: @MainActor (ArraySlice<Entity>, Float, any SceneEnvironment) -> Void

    /// Environment-aware step: receives the injected `SceneEnvironment` so the step can read
    /// device pose, hand input, RNG, etc. from scriptable providers.
    public init(_ name: String, _ body: @MainActor @escaping (ArraySlice<Entity>, Float, any SceneEnvironment) -> Void) {
        self.name = name
        self.body = body
    }

    /// Back-compat step that ignores the environment — keeps existing `(entities, dt)`
    /// call sites compiling unchanged.
    public init(_ name: String, _ body: @MainActor @escaping (ArraySlice<Entity>, Float) -> Void) {
        self.name = name
        self.body = { entities, dt, _ in body(entities, dt) }
    }
}
