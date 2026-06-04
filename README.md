# ImmersiveTesting

Unit-test immersive visionOS / RealityKit content **without a headset**. Spatial
assertions, a headless scene-builder DSL, deterministic ECS system simulation, and
declarative scene-state verification for `ImmersiveView`-style scenes.

> Built on the insight that `Entity`, `Transform`, and most `Component`s instantiate fine
> in a plain `XCTest` — so the entity graph you assert against is exactly what RealityKit
> holds at runtime. Runs on macOS CI for fast logic tests.

See [`docs/VISIONOS-TESTING-NOTES.md`](docs/VISIONOS-TESTING-NOTES.md) for gotchas
(`@MainActor` everywhere, hostless vs hosted test bundles, the immersive-app sim-shell crash,
name-lookup rules).

## Install

```swift
.package(path: "../ImmersiveTesting")  // local
// or
.package(url: "https://github.com/<you>/ImmersiveTesting.git", from: "1.1.0")
```

---

## v1.2 — what's new

### Dependency injection — drive real scenes headlessly

Four provider protocols isolate the runtime services an immersive scene reaches for through
singletons / live ARKit, each with a scriptable package fake. A `SceneEnvironment` bundles them
and is injected into scene builders and system steps. See **[docs/DEPENDENCY-INJECTION.md](docs/DEPENDENCY-INJECTION.md)**.

```swift
let world = FakeWorldTracking()
let env = CompositeSceneEnvironment(worldTracking: world, random: SeededRandom(seed: 42))

// A production builder conforms to SceneBuilder → callable in tests with a fake env:
let scene = SurvivalSceneBuilder().makeScene(.init(wave: 1, zombieCount: 3), env: env)

let harness = SystemHarness(scene: scene, environment: env)
harness.registerStep("chase") { entities, dt, env in
    let player = env.worldTracking.devicePosition()        // scripted, deterministic
    for e in entities where e.components[ZombieTag.self] != nil {
        e.position += normalize(player - e.position) * dt
    }
}
world.position = [20, 0, 0]                                 // move the player mid-simulation
harness.tick(frames: 90, invariants: SceneInvariantSet { SceneInvariant.noNaNTransforms })
```

| Type | Purpose |
|------|---------|
| `WorldTrackingProviding` / `FakeWorldTracking` | Device pose; replaces `WorldTrackingManager.shared` |
| `SceneEffectsProviding` / `SpySceneEffects` | Scene-effect calls; records for assertions |
| `HandTrackingProviding` / `ScriptedHands` | Pinch distances + gun-tip pose |
| `RandomProviding` / `SeededRandom` | Deterministic, seedable RNG (SplitMix64) |
| `SceneEnvironment` / `CompositeSceneEnvironment` | Injection container (all-fakes by default) |
| `SceneBuilder` | `build(_ config:, env:) -> Entity`; `makeScene(…)` wraps in a `TestScene` |
| `TestScene(adopting:)` | Wrap a real builder's root for assertions |

`SystemHarness` gained an `environment` and an env-aware `registerStep` overload; the old
`(entities, dt)` overload is unchanged, so existing tests keep compiling.

## v1.1 — what's new

### SceneStateSpec — declarative scene-state assertions

The headline feature. Describe what the entity graph *must* look like in a given game state,
then assert it after the state transition. One spec call gives you a rich pass/fail summary
listing every requirement, not just the first failure.

```swift
@MainActor
final class WaveTests: XCTestCase {

    func testStartingWaveConfiguresScene() {
        let scene = TestScene {
            Entity("player").position(0, 1.6, 0).component(HealthComponent(lives: 3))
        }
        let vm = ViewModel(scene: scene.root)
        vm.startWave()

        SceneStateSpec("waveActive") {
            Requires(entityNamed: "objectiveAnchor")
            Requires(atLeast: 1, matching: .hasComponent(ZombieAIComponent.self))
            Requires(exactly: 1, matching: .named("player"))
            Forbids(entityNamed: "mainMenuPanel")
            Expect(entityNamed: "player", "lives == 3") { entity in
                entity.components[HealthComponent.self]?.lives == 3
            }
        }.assert(against: scene.root)
    }
}
```

**Failure output:**
```
SceneStateSpec "waveActive" failed (2 violations):
  ✗ requires entity "objectiveAnchor"                    — not found
  ✗ forbids entity "mainMenuPanel"                      — present at /root/ui/mainMenuPanel
  ✓ at least 1 has ZombieAIComponent                   — found 3
  ✓ exactly 1 named "player"                            — found 1
  ✓ player: lives == 3                                  — ✓
```

### SceneInvariantSet — frame-level invariants

Conditions that must hold *every frame* of simulation. Pass to `SystemHarness.tick` to fail
on the exact frame a property breaks, not after the run completes.

```swift
let invariants = SceneInvariantSet {
    SceneInvariant.noNaNTransforms
    SceneInvariant.alwaysPresent(named: "player")
    SceneInvariant.neverPresent(named: "mainMenuPanel")
    SceneInvariant.cap(ProjectileComponent.self, atMost: 50)
    SceneInvariant("player never below floor") { root in
        (root.findEntity(named: "player")?.worldPosition.y ?? 0) > -0.1
    }
}

harness.tick(frames: 300, invariants: invariants)
```

### SystemHarness + FrameClock — deterministic ECS simulation

Drive closure-based system steps frame-by-frame against a `TestScene`. Deterministic time,
per-frame invariant checks, and a `tickUntil` helper for event-driven assertions.

```swift
let scene = TestScene { Entity("projectile").component(ProjectileComponent(velocity: [0, 0, -60])) }
let harness = SystemHarness(scene: scene)   // default 90 Hz clock

harness.registerStep("motion") { entities, dt in
    for e in entities {
        guard let proj = e.components[ProjectileComponent.self], !proj.hitRegistered else { continue }
        e.position = e.position + proj.velocity * dt
    }
}

harness.tick(frames: 90)   // 1 second of simulated time
XCTAssertPosition(scene["projectile"]!, near: [0, 0, -60], within: 0.5)

// Or wait for a condition:
harness.tickUntil("projectile past z=-30", maxFrames: 200) {
    scene["projectile"]!.position.z < -30
}
```

**Blessed pattern for real `System`s** — extract the logic into a static method your `System`
delegates to, then register that same method in the harness:

```swift
// In your app:
struct MotionSystem: System {
    func update(context: SceneUpdateContext) {
        let entities = context.entities.compactMap { $0 as? Entity }
        MotionSystem.step(entities: entities, dt: Float(context.deltaTime))
    }
    static func step(entities: [Entity], dt: Float) { /* pure logic */ }
}

// In your test:
harness.registerStep("motion") { entities, dt in MotionSystem.step(entities: Array(entities), dt: dt) }
```

### SceneSnapshot — structural diffing & tree dumps

Capture the entity graph as a value type for debugging, golden-file regression, and
pre/post state comparison.

```swift
let before = SceneSnapshot(scene.root)

viewModel.triggerExplosion()

let after = SceneSnapshot(scene.root)
XCTAssertSnapshotsMatch(after, baseline: before)   // fails with diff on change

// Or just print the tree for debugging:
print(before.tree)
/*
 root
 ├─ player  pos(0.00, 1.60, 0.00)
 └─ zombie  pos(0.00, 0.00, -3.00)  group:8192
    ├─ head  pos(0.00, 1.70, -3.00)  group:524288
    └─ torso  pos(0.00, 1.10, -3.00)  group:524288
*/
```

---

## Full assertion reference

### v0.1 — Spatial & component assertions

| Category | Assertions |
|----------|-----------|
| Position | `XCTAssertPosition(_:near:within:)`, `XCTAssertWorldPosition(_:equals:accuracy:)`, `XCTAssertDistance(_:to:lessThan:)` |
| Orientation | `XCTAssertFacing(_:towards:tolerance:)`, `XCTAssertUpright(_:tolerance:)` |
| Scale / sanity | `XCTAssertWorldScale(_:equals:accuracy:)`, `XCTAssertFiniteTransforms(_:)`, `XCTAssertUniformScale(_:equals:accuracy:)` |
| Components | `XCTAssertHasComponent`, `XCTAssertNoComponent`, `XCTAssertComponent(…satisfies:)`, `XCTAssertComponentCount` |
| Hierarchy | `XCTAssertChild(of:)`, `XCTAssertDescendant(of:)`, `XCTAssertEntityExists(named:)`, `XCTAssertNoEntity(named:)` |
| Collision | `XCTAssertColliderGroup(contains:)`, `XCTAssertColliderMask(contains:)`, `XCTAssertCollides(with:)`, `XCTAssertNoCollision(with:)`, `XCTAssertNoCollider(_:)` |

Angle tolerances use `Angle` (`.degrees(15)` / `.radians(_:)`) — no raw-radian foot-guns.
`XCTAssertCollides` reads `CollisionComponent.filter` (group ⊗ mask) so it verifies your
collision-group registry contract without running physics.

### v1.1 — Entity structure assertions

| Assertion | What it checks |
|-----------|---------------|
| `XCTAssertEntityName(_:_:)` | Resolves an optional entity and verifies its name |
| `XCTAssertChildCount(_:_:)` | Exact direct child count |
| `XCTAssertHasChildren(_:)` | Parent has at least one child |
| `XCTAssertNoChildren(_:)` | Parent has zero children |
| `XCTAssertEnabled(_:)` / `XCTAssertDisabled(_:)` | `entity.isEnabled` |
| `XCTAssertSubtreeSize(_:equals:)` | Total entity count in subtree (including root) |
| `XCTAssertRoot(_:)` / `XCTAssertHasParent(_:)` | Presence / absence of a parent |

### v1.1 — Scene-state API

| Type | Purpose |
|------|---------|
| `SceneStateSpec` | Declarative expectations; call `.assert(against:)` |
| `SceneRequirement` | `Requires`, `Forbids`, `Expect`, `Requires(atLeast:)`, `Requires(exactly:)`, `Requires(atMost:)` |
| `EntityPredicate` | `.hasComponent(_:)`, `.named(_:)`, `.satisfies(_:_:)` |
| `SceneInvariantSet` | Set of invariants checked per frame |
| `SceneInvariant` | Named condition on the root entity |
| `SceneSnapshot` | Structural tree capture; `snap.tree`, `XCTAssertSnapshotsMatch` |
| `SystemHarness` | Drives simulation steps; `tick(frames:invariants:)`, `tickUntil` |
| `FrameClock` | Deterministic time; `deltaTime`, `advance(frames:)`, `reset()` |

---

## Roadmap

- ✅ **v1.2** Dependency-injection layer — provider protocols, scriptable fakes,
  `SceneEnvironment`, `SceneBuilder`, env-aware `SystemHarness`. See
  [docs/DEPENDENCY-INJECTION.md](docs/DEPENDENCY-INJECTION.md).
- **v1.3** Record a real ARKit session on-device → replay deterministically in CI
  (provider protocols are the seam this plugs into)
- **later** Offscreen render snapshot product (Metal surface required, GPU-flaky — deferred)
