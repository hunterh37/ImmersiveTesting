import RealityKit

// MARK: - SceneEnvironment
//
// The dependency-injection container handed to scene builders and ECS system steps in place
// of reaching for `.shared` singletons. It bundles the runtime service providers (device
// pose, scene effects, hands, randomness) so a builder signature stays small:
// `build(_ config:, env:)`, and so each service has exactly one swap point.
//
// Production wires live adapters: `CompositeSceneEnvironment(worldTracking: liveAdapter, …)`,
// where each adapter conforms the real `.shared` manager to its provider protocol. The same
// seam lets a test (or the headless renderer) substitute a scripted fake — but the primary
// purpose is decoupling app logic from the platform, not mocking.

/// Read access to the runtime services an immersive scene depends on.
@MainActor
public protocol SceneEnvironment {
    var worldTracking: any WorldTrackingProviding { get }
    var sceneEffects:  any SceneEffectsProviding  { get }
    var hands:         any HandTrackingProviding   { get }
    var random:        any RandomProviding         { get }
}

// MARK: - CompositeSceneEnvironment

/// The concrete, swap-anything environment. Every provider defaults to its package fake, so
/// `CompositeSceneEnvironment()` is a fully scriptable headless world; pass real adapters to
/// build a production environment.
///
/// ```swift
/// // Test:
/// let world = FakeWorldTracking()
/// let env = CompositeSceneEnvironment(worldTracking: world, random: SeededRandom(seed: 7))
///
/// // Production (in the app):
/// let env = CompositeSceneEnvironment(
///     worldTracking: LiveWorldTracking(),     // wraps WorldTrackingManager.shared
///     sceneEffects:  LiveSceneEffects(),       // wraps SceneReconstructionManager.shared
///     hands:         LiveHands()               // wraps HandGestureModel
/// )
/// ```
@MainActor
public final class CompositeSceneEnvironment: SceneEnvironment {
    public var worldTracking: any WorldTrackingProviding
    public var sceneEffects:  any SceneEffectsProviding
    public var hands:         any HandTrackingProviding
    public var random:        any RandomProviding

    public init(
        worldTracking: any WorldTrackingProviding = FakeWorldTracking(),
        sceneEffects:  any SceneEffectsProviding  = SpySceneEffects(),
        hands:         any HandTrackingProviding   = ScriptedHands(),
        random:        any RandomProviding         = SeededRandom()
    ) {
        self.worldTracking = worldTracking
        self.sceneEffects = sceneEffects
        self.hands = hands
        self.random = random
    }
}

// MARK: - Ergonomic factories

public extension SceneEnvironment where Self == CompositeSceneEnvironment {
    /// A fully-fake environment. Optionally override individual providers inline.
    static func fake(
        worldTracking: any WorldTrackingProviding = FakeWorldTracking(),
        sceneEffects:  any SceneEffectsProviding  = SpySceneEffects(),
        hands:         any HandTrackingProviding   = ScriptedHands(),
        random:        any RandomProviding         = SeededRandom()
    ) -> CompositeSceneEnvironment {
        CompositeSceneEnvironment(
            worldTracking: worldTracking,
            sceneEffects: sceneEffects,
            hands: hands,
            random: random
        )
    }
}
