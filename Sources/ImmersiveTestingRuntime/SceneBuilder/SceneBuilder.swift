import RealityKit

// MARK: - SceneBuilder
//
// The contract a production graph builder adopts so the same code that runs in the headset
// can be exercised headlessly. Instead of constructing entities while reaching into
// singletons and a live `Scene`, a builder is a pure function of `(Config, SceneEnvironment)`
// returning a root `Entity`. Production calls it with a live environment; tests call it with
// a fake one and assert the resulting graph.
//
// This is the "swap point" the visionOS testing notes anticipate: once the app's
// `WaveManager` (or a dedicated `SurvivalSceneBuilder`) conforms, a fixture stops
// re-declaring stand-in components and calls the real builder — the assertions then guard
// real construction logic.

/// Builds an immersive scene's entity graph deterministically from a configuration and an
/// injected environment.
@MainActor
public protocol SceneBuilder {
    /// The per-build inputs (wave number, zombie count, mode flags, …).
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
