import RealityKit

// MARK: - SceneBuilder
//
// The contract for the layer that constructs an immersive scene's entity graph. Instead of
// building entities inline in a `RealityView` closure while reaching into singletons and a
// live `Scene`, a builder is a function of `(Config, SceneEnvironment)` returning a root
// `Entity`. Runtime dependencies (device pose, randomness) come through `env` rather than
// `.shared`, so scene construction stays in one place and the services it uses are
// swappable.
//
// Because construction doesn't touch a live `Scene`, the same builder also runs on macOS —
// which is what lets the verification tooling render and assert on the graph. That's a
// convenience, not the reason the type exists.

/// Builds an immersive scene's entity graph deterministically from a configuration and an
/// injected environment.
@MainActor
public protocol SceneBuilder {
    /// The per-build inputs (round number, entity count, mode flags, …).
    associatedtype Config

    /// Produces the root entity for the scene in the given configuration. Must not touch
    /// global singletons directly — read everything runtime-dependent from `env`.
    func build(_ config: Config, env: any SceneEnvironment) -> Entity
}

public extension SceneBuilder {
    /// Builds the graph and wraps it in a `TestScene` ready for assertions, defaulting to a
    /// fully-fake environment.
    func makeScene(
        _ config: Config,
        env: any SceneEnvironment = CompositeSceneEnvironment()
    ) -> TestScene {
        TestScene(adopting: build(config, env: env))
    }
}

public extension SceneBuilder where Config == Void {
    /// Convenience for parameterless builders.
    func makeScene(env: any SceneEnvironment = CompositeSceneEnvironment()) -> TestScene {
        TestScene(adopting: build((), env: env))
    }
}
