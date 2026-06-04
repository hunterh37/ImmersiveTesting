# Dependency injection & buildable scenes

How to make a real immersive RealityKit scene testable headlessly with ImmersiveTesting.

The package can already **build** entity graphs (`TestScene`/`@EntityBuilder`), **drive** them
(`SystemHarness`/`FrameClock`), and **assert** them (`SceneStateSpec`/`SceneInvariant`/
`SceneSnapshot`). What was missing was a way to *obtain a real scene* under test: production
builders reach into singletons (`WorldTrackingManager.shared`) and un-fakeable ARKit
providers, so tests had to hand-copy a stand-in graph. This DI layer closes that gap.

---

## The four providers

Each protocol isolates one runtime service a scene normally reaches for through a singleton or
live ARKit. They're expressed purely in RealityKit / simd value types, so the package stays
ARKit-free and runs on macOS CI.

| Protocol | Replaces (in the game) | Package fake |
|---|---|---|
| `WorldTrackingProviding` | `WorldTrackingManager.shared.getOriginFromDeviceTransform()` | `FakeWorldTracking` |
| `SceneEffectsProviding` | `SceneReconstructionManager.shared` glitch calls | `SpySceneEffects` |
| `HandTrackingProviding` | `HandGestureModel` / ARKit hand pose | `ScriptedHands` |
| `RandomProviding` | `Float.random` / `SystemRandomNumberGenerator` | `SeededRandom` |

The fakes are reference types you script between ticks:

```swift
let world = FakeWorldTracking()
world.position = [5, 1.6, 0]          // teleport the simulated head

let hands = ScriptedHands()
hands.rightPinchDistance = 0.05       // closed → fires (below the 0.09 m rule)

let fx = SpySceneEffects()            // records startEffect(named:) calls for assertions
let rng = SeededRandom(seed: 42)      // reproducible "random" spawns
```

## The environment container

`SceneEnvironment` bundles the four providers; `CompositeSceneEnvironment` is the concrete
implementation that defaults every provider to its fake. The **same type** serves tests and
production — production just passes live adapters instead of fakes.

```swift
// Test — fully scriptable headless world:
let env = CompositeSceneEnvironment(worldTracking: world, random: SeededRandom(seed: 7))
let env2: any SceneEnvironment = .fake(hands: hands)        // factory sugar

// Production (in the app) — adapters wrap the real `.shared` managers:
let env = CompositeSceneEnvironment(
    worldTracking: LiveWorldTracking(),    // calls WorldTrackingManager.shared
    sceneEffects:  LiveSceneEffects(),      // calls SceneReconstructionManager.shared
    hands:         LiveHands()              // wraps HandGestureModel
)
```

## Buildable scenes — the `SceneBuilder` contract

A production graph builder adopts `SceneBuilder` so the same code that runs in the headset can
run headlessly. It becomes a pure function of `(Config, SceneEnvironment) -> Entity` — no
singleton access inside; read everything runtime-dependent from `env`.

```swift
struct SurvivalSceneBuilder: SceneBuilder {
    struct Config { var wave: Int; var zombieCount: Int }

    func build(_ config: Config, env: any SceneEnvironment) -> Entity {
        let root = Entity("survivalRoot")
        let player = env.worldTracking.devicePosition()
        for i in 0..<config.zombieCount {
            let pos = player + env.random.unitVectorXZ() * 4.0
            root.addChild(Entity("zombie_\(i)").position(pos) /* … components … */)
        }
        return root
    }
}
```

`makeScene` wraps the result in a `TestScene` ready for assertions:

```swift
let scene = SurvivalSceneBuilder().makeScene(.init(wave: 1, zombieCount: 3),
                                             env: .fake(random: SeededRandom(seed: 1)))
SceneStateSpec("waveActive") {
    Requires(atLeast: 1, matching: .hasComponent(ZombieTag.self))
}.assert(against: scene.root)
```

## Environment-aware systems

`SystemHarness` now carries a `SceneEnvironment` (defaulting to all-fakes) and passes it to a
new three-argument `registerStep` overload. The old `(entities, dt)` overload is untouched, so
existing steps keep compiling.

```swift
let harness = SystemHarness(scene: scene, environment: env)
harness.registerStep("chase") { entities, dt, env in
    let target = env.worldTracking.devicePosition()       // scripted, deterministic
    for e in entities where e.components[ZombieTag.self] != nil {
        e.position += normalize(target - e.position) * dt
    }
}
world.position = [20, 0, 0]                                // move the player mid-sim
harness.tick(frames: 90, invariants: SceneInvariantSet { SceneInvariant.noNaNTransforms })
```

## End-to-end example

```swift
@MainActor
func testZombiesChaseMovingPlayer() {
    let world = FakeWorldTracking()
    let env = CompositeSceneEnvironment(worldTracking: world, random: SeededRandom(seed: 42))

    let scene = SurvivalSceneBuilder().makeScene(.init(wave: 1, zombieCount: 3), env: env)
    let harness = SystemHarness(scene: scene, environment: env)
    harness.registerStep("ai") { e, dt, env in MovingTargetSystem.step(e, dt, env) }

    world.position = [5, 1.6, 0]
    harness.tick(frames: 90, invariants: SceneInvariantSet {
        SceneInvariant.noNaNTransforms
    })

    for z in scene.root.entities(with: ZombieTag.self) {
        XCTAssertLessThan(z.worldPosition.x, 5)   // deterministic — same every run via the seed
    }
}
```

---

## Adopting this in ZombieShooter (migration)

DI only pays off once the game's singleton calls become injected calls. The migration is
mechanical and backward-compatible:

1. **Conform the real managers** to the provider protocols via thin adapters (keep `.shared`
   for production): `LiveWorldTracking`, `LiveSceneEffects`, `LiveHands`.
2. **Extract graph construction** out of `WaveManager` into a `SurvivalSceneBuilder: SceneBuilder`.
   Replace `WorldTrackingManager.shared.…` reads with `env.worldTracking.…` and
   `SceneReconstructionManager.shared.startGlitchCycle()` with `env.sceneEffects.startEffect(named:)`.
3. **Default the env parameter** to a live environment so production call sites don't change.
4. **Flip the fixture:** `SurvivalScene.make` calls `SurvivalSceneBuilder().build(_, env:)`; delete
   the duplicated stand-in components (`ZombieTag`/`PlayerTag`/`CG`) once the real components are
   importable. This is the swap point described in `VISIONOS-TESTING-NOTES.md` §6.

Until step 4, hostless tests keep using the package's fakes against the contract; afterwards the
same assertions guard the real builder.

## Design notes / blind spots handled

- **Non-breaking harness:** `SystemStep` gained an env-aware initializer plus a back-compat one
  that ignores the env; `SystemHarness.init` and `registerStep` env params are defaulted. All 49
  pre-existing tests pass unchanged.
- **No second clock:** the environment deliberately does **not** own a clock — `SystemHarness`
  remains the single time source (`FrameClock`). Mixing two clocks was the obvious foot-gun.
- **ARKit stays out:** providers never reference `DeviceAnchor`/`HandAnchor`; the app bridges
  those in its adapters.
- **Determinism:** `SeededRandom` is SplitMix64 with a 24-bit mantissa extraction — exact floats
  in `[0,1)`, no overflow, identical sequences across runs and machines.
- **`@MainActor` throughout:** every new type is main-actor isolated to match RealityKit's
  `Entity` isolation under Swift 6.
