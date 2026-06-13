# ImmersiveTesting

A **scaffold for building immersive visionOS / RealityKit apps** — a layered architecture
plus a small set of services that keep spatial 3D code clean instead of tangled into a
`RealityView` closure. You build your app on the `Runtime` layer (`SceneBuilder`, ECS
systems, a `SceneEnvironment` for injected services); RealityKit still does the heavy
lifting — physics, rendering, collisions.

> **The name is historical.** The package grew out of a testing toolkit, but its job is to
> be the *structure you build immersive apps on*. The headless-assertion and render-capture
> tooling (below) are conveniences that fall out of that structure — not the point.

**What it gives you:**

**1. A clean app skeleton.** Three layers — thin `ImmersiveView` shell → `SceneBuilder` +
systems → provider-protocol services behind a `SceneEnvironment`. Your scene construction,
game logic, and ARKit/`.shared` calls each live in one place and stay swappable. See the
[architecture guide](#architecture-guide--building-on-the-scaffold).

**2. Real RealityKit physics — not hand-rolled math.** Motion, gravity, floors, and
contacts are RealityKit's job: give entities `PhysicsBodyComponent` + `CollisionComponent`
and let the engine solve them. The scaffold is about *structure and dependency injection*,
**not** about replacing the physics engine. See [Use real physics](#use-real-physics).

**3. You can see and check a scene without a headset.** Because the entity graph builds
identically on macOS, you can render a scene to a PNG (`swift run ImmersiveCaptureApp`,
[docs/RENDER-CAPTURE.md](docs/RENDER-CAPTURE.md)) and assert on its structure in a plain
`XCTest`. Handy for CI and for coding agents iterating on spatial code — a *byproduct* of
the layering, not its reason to exist.

For gotchas (`@MainActor` everywhere, hostless vs hosted test bundles, the immersive-app
sim-shell crash, name-lookup rules) see [docs/VISIONOS-TESTING-NOTES.md](docs/VISIONOS-TESTING-NOTES.md).

## Install

```swift
.package(path: "../ImmersiveTesting")  // local
// or
.package(url: "https://github.com/hunterh37/ImmersiveTesting.git", from: "1.3.0")
```

## Requirements

- Swift 6 / Xcode 16 or newer
- macOS 15, iOS 18, or visionOS 2
- `ImmersiveTestingRuntime` is XCTest-free and can be linked from app targets.
- `ImmersiveTesting` imports XCTest and should be used from test targets only.
- `ImmersiveCaptureApp` and `ImmersiveTestingMCP` are optional agent/debugging tools; the
  core assertion/runtime libraries do not require MCP.

---

## Architecture guide — building on the scaffold

Structure the app in three layers. The goal is *separation of concerns*: scene
construction, frame logic, and platform services each live in one swappable place.
(A pleasant side effect — everything above the services line is constructible on macOS
without a headset, which is what makes the headless tooling work.)

```
┌─────────────────────────────────────────────────────────┐
│  SwiftUI / ImmersiveView  (thin shell — no logic)       │
│  • creates the SceneEnvironment with live adapters      │
│  • calls SceneBuilder.makeScene(_:env:)                 │
│  • passes root into RealityView                         │
└───────────────────┬─────────────────────────────────────┘
                    │ Entity root
┌───────────────────▼─────────────────────────────────────┐
│  Scene layer  (SceneBuilder + ECS Systems)              │
│  • SceneBuilder: pure (Config, SceneEnvironment)→Entity │
│  • Systems: static step(entities:dt:env:) pure logic    │
│  • ViewModel drives state transitions on the root       │
└───────────────────┬─────────────────────────────────────┘
                    │ provider protocols
┌───────────────────▼─────────────────────────────────────┐
│  Services layer  (SceneEnvironment)                     │
│  • Live*  adapters in the app  (ARKit / .shared calls)  │
│  • Fake*  / Scripted*  in tests (deterministic, fast)   │
└─────────────────────────────────────────────────────────┘
```

**Rule of thumb:** if a type imports `ARKit` or calls `.shared`, it belongs in the services
layer behind a provider protocol.

### Use real physics

The scaffold organizes your code; it does **not** replace RealityKit's simulation. For
anything that moves, falls, rests on a surface, or collides, use the engine:

- Give dynamic bodies a `PhysicsBodyComponent` + `CollisionComponent`; give floors/walls a
  **static** `PhysicsBodyComponent` (`.static`) with a matching collider. RealityKit then
  resolves gravity, contacts, and resting automatically — a blade *cannot* sink through a
  floor that has a real collider.
- Read/apply forces and impulses (`PhysicsMotionComponent`, `applyLinearImpulse`) rather
  than integrating `position += velocity * dt` by hand.
- Use `CollisionEvents` (or the `CollisionComponent.filter` group/mask) for hit detection.

A `step(entities:dt:env:)` system is for **game logic** — AI, scoring, state transitions,
spawning, tuning forces — *not* for re-implementing gravity and floor clamps. Hand-rolled
motion is how you get bugs like objects clipping through meshes; let the solver own the
solver's job.

> The `static step` pattern below makes logic easy to reason about and to drive headlessly.
> That's orthogonal to physics: your steps should *nudge the physics engine*, not stand in
> for it.

### 1. Keep ImmersiveView as a thin shell

`ImmersiveView` / `RealityView` only wires the layers together — no logic, no state, no
entity construction:

```swift
struct GameImmersiveView: View {
    @StateObject private var viewModel = GameViewModel()

    var body: some View {
        RealityView { content in
            let env = CompositeSceneEnvironment(
                worldTracking: LiveWorldTracking(),
                sceneEffects:  LiveSceneEffects(),
                hands:         LiveHands()
            )
            let scene = GameSceneBuilder().makeScene(viewModel.config, env: env)
            content.add(scene.root)
            viewModel.sceneRoot = scene.root
        }
    }
}
```

### 2. Extract scene construction into a `SceneBuilder`

A `SceneBuilder` is a pure function `(Config, SceneEnvironment) → Entity`. All
runtime-dependent reads (device pose, randomness) go through `env`:

```swift
struct GameSceneBuilder: SceneBuilder {
    struct Config { var round: Int; var npcCount: Int; var difficulty: Difficulty }

    func build(_ config: Config, env: any SceneEnvironment) -> Entity {
        let root = Entity("sceneRoot")
        let devicePos = env.worldTracking.devicePosition()

        for i in 0..<config.npcCount {
            let offset = env.random.unitVectorXZ() * Float(3 + config.difficulty.spawnRadius)
            let npc = Entity("npc_\(i)")
            npc.position = devicePos + offset
            npc.components.set(NPCTag())
            root.addChild(npc)
        }
        return root
    }
}
```

Because `build` is pure, a test just provides a fake environment and asserts the graph:

```swift
@MainActor
func testRoundOneSpawnsCorrectNPCCount() {
    let env = CompositeSceneEnvironment(random: SeededRandom(seed: 1))
    let scene = GameSceneBuilder().makeScene(.init(round: 1, npcCount: 5, difficulty: .normal), env: env)

    SceneStateSpec("round-1") {
        Requires(exactly: 5, matching: .hasComponent(NPCTag.self))
        Requires(entityNamed: "avatar")
    }.assert(against: scene.root)
}
```

### 3. Extract system logic into static methods

`SceneUpdateContext` has no public initializer, so `update(context:)` can never be called
from a test. Extract the core logic into a static method the real `System` delegates to —
that's what `SystemHarness` drives:

```swift
struct NPCAISystem: System {
    required init(scene: RealityKit.Scene) {}

    func update(context: SceneUpdateContext) {
        let entities = context.scene.performQuery(Self.query).map { $0 }
        NPCAISystem.step(entities: entities, dt: Float(context.deltaTime), env: GameEnvironment.shared)
    }

    static let query = EntityQuery(where: .has(NPCTag.self))

    // ✅ This is what tests drive — no SceneUpdateContext, no scene query
    static func step(entities: [Entity], dt: Float, env: any SceneEnvironment) {
        let target = env.worldTracking.devicePosition()
        for npc in entities {
            guard var ai = npc.components[NPCAIComponent.self] else { continue }
            npc.position += normalize(target - npc.position) * ai.speed * dt
        }
    }
}
```

```swift
func testNPCsChaseDevice() {
    let world = FakeWorldTracking()
    world.position = [5, 1.6, 0]
    let env = CompositeSceneEnvironment(worldTracking: world, random: SeededRandom(seed: 42))

    let scene = GameSceneBuilder().makeScene(.init(round: 1, npcCount: 3, difficulty: .normal), env: env)
    let harness = SystemHarness(scene: scene, environment: env)
    harness.registerStep("npc-ai") { entities, dt, env in
        NPCAISystem.step(entities: Array(entities), dt: dt, env: env)
    }

    harness.tick(frames: 90, invariants: SceneInvariantSet { SceneInvariant.noNaNTransforms })

    for npc in scene.root.children where npc.components[NPCTag.self] != nil {
        XCTAssertLessThan(npc.position.x, 5)
    }
}
```

### 4. Hide singleton / ARKit calls behind provider protocols

Wrap every `.shared` / ARKit call in a thin `Live*` adapter so tests can substitute a fake:

```swift
final class LiveWorldTracking: WorldTrackingProviding {
    func devicePosition() -> SIMD3<Float> {
        WorldTrackingManager.shared.getOriginFromDeviceTransform()?.columns.3.xyz ?? .zero
    }
}

// Production wires the live adapters once, at the ImmersiveView layer:
extension GameEnvironment {
    static let live = CompositeSceneEnvironment(
        worldTracking: LiveWorldTracking(),
        sceneEffects:  LiveSceneEffects(),
        hands:         LiveHands()
    )
}
```

### 5. Use `ViewModel` for state transitions, not layout

`ViewModel` owns the game-state machine and operates on the root entity it was handed — it
doesn't construct the scene. Inject the env via init, defaulting to `.fake()` so a test
needs zero setup:

```swift
@MainActor
final class GameViewModel: ObservableObject {
    @Published var state: GameState = .menu
    var sceneRoot: Entity?
    private let env: any SceneEnvironment

    init(env: any SceneEnvironment = .fake()) { self.env = env }

    func startRound(_ config: GameSceneBuilder.Config) {
        state = .playing(round: config.round)
        sceneRoot?.findEntity(named: "mainMenuPanel")?.isEnabled = false
        env.sceneEffects.startEffect(named: "roundStart")
    }
}
```

```swift
@MainActor
func testStartRoundHidesMenu() {
    let scene = TestScene {
        Entity("mainMenuPanel")
        Entity("objectiveAnchor").disabled()
    }
    let vm = GameViewModel()
    vm.sceneRoot = scene.root

    vm.startRound(.init(round: 1, npcCount: 3, difficulty: .normal))

    XCTAssertDisabled(scene["mainMenuPanel"]!)
}
```

### Best practices at a glance

| Rule | Why |
|------|-----|
| `ImmersiveView` creates the env + calls `makeScene` — nothing else | keeps the shell replaceable without touching logic |
| `SceneBuilder.build` is a pure `(Config, env) → Entity` | makes the builder unit-testable headlessly |
| Motion/collision use RealityKit physics components | the engine owns gravity, contacts, and resting — don't hand-roll them |
| Systems expose `static step(entities:dt:env:)` for *logic* | keeps game/AI/state logic isolated and callable without a `SceneUpdateContext` |
| All `.shared` / ARKit calls live in `Live*` adapters | one seam per service — swap the backend (or a fake) without touching logic |
| `ViewModel` receives env via init, defaults to `.fake()` | trivially constructible in any context |
| Use `SeededRandom` for procedural layout | runs replay byte-for-byte; deterministic spawns |
| Scenes build headlessly on macOS | enables render capture + CI assertions, no simulator needed |

For the full DI API reference see [docs/DEPENDENCY-INJECTION.md](docs/DEPENDENCY-INJECTION.md).

---

## Verifying scenes headlessly

Everything below is the optional verification layer (`import ImmersiveTesting`, test targets
only). It exists because the scaffold builds scenes on macOS — use it for CI and agent
loops, but none of it is required to *build* an app on the Runtime layer.

### SceneStateSpec — declarative scene-state assertions

Describe what the entity graph *must* look like in a given app state, then assert it. One
spec call reports every requirement, not just the first failure:

```swift
SceneStateSpec("roundActive") {
    Requires(entityNamed: "objectiveAnchor")
    Requires(atLeast: 1, matching: .hasComponent(NPCAIComponent.self))
    Forbids(entityNamed: "mainMenuPanel")
    Expect(entityNamed: "avatar", "lives == 3") { entity in
        entity.components[VitalComponent.self]?.lives == 3
    }
}.assert(against: scene.root)
```

```
SceneStateSpec "roundActive" failed (2 violations):
  ✗ requires entity "objectiveAnchor"                    — not found
  ✗ forbids entity "mainMenuPanel"                      — present at /root/ui/mainMenuPanel
  ✓ at least 1 has NPCAIComponent                      — found 3
```

### SystemHarness + FrameClock — deterministic ECS simulation

Drive system steps frame-by-frame against a `TestScene` with deterministic time (default
90 Hz). `SceneInvariantSet` conditions are checked *every frame*, so a run fails on the
exact frame a property breaks:

```swift
let scene = TestScene { Entity("projectile").component(ProjectileComponent(velocity: [0, 0, -60])) }
let harness = SystemHarness(scene: scene)

harness.registerStep("motion") { entities, dt in
    MotionSystem.step(entities: Array(entities), dt: dt)
}

let invariants = SceneInvariantSet {
    SceneInvariant.noNaNTransforms
    SceneInvariant.alwaysPresent(named: "avatar")
    SceneInvariant.cap(ProjectileComponent.self, atMost: 50)
    SceneInvariant("avatar never below floor") { root in
        (root.findEntity(named: "avatar")?.worldPosition.y ?? 0) > -0.1
    }
}

harness.tick(frames: 90, invariants: invariants)   // 1 second of simulated time
XCTAssertPosition(scene["projectile"]!, near: [0, 0, -60], within: 0.5)

// Or wait for a condition:
harness.tickUntil("projectile past z=-30", maxFrames: 200) {
    scene["projectile"]!.position.z < -30
}
```

### Dependency injection — drive real scenes headlessly

Provider protocols isolate the runtime services a scene reaches for, each with a
scriptable fake. A `SceneEnvironment` bundles them and is injected into builders and
system steps. Fakes can be mutated mid-simulation (e.g. move the device):

```swift
let world = FakeWorldTracking()
let env = CompositeSceneEnvironment(worldTracking: world, random: SeededRandom(seed: 42))
let scene = SpawnSceneBuilder().makeScene(.init(round: 1, npcCount: 3), env: env)

let harness = SystemHarness(scene: scene, environment: env)
harness.registerStep("chase") { entities, dt, env in
    let target = env.worldTracking.devicePosition()        // scripted, deterministic
    for e in entities where e.components[NPCTag.self] != nil {
        e.position += normalize(target - e.position) * dt
    }
}
world.position = [20, 0, 0]                                 // move the device mid-simulation
harness.tick(frames: 90, invariants: SceneInvariantSet { SceneInvariant.noNaNTransforms })
```

| Type | Purpose |
|------|---------|
| `WorldTrackingProviding` / `FakeWorldTracking` | Device pose; replaces `WorldTrackingManager.shared` |
| `SceneEffectsProviding` / `SpySceneEffects` | Scene-effect calls; records for assertions |
| `HandTrackingProviding` / `ScriptedHands` | Pinch distances + pointer-tip pose |
| `RandomProviding` / `SeededRandom` | Deterministic, seedable RNG (SplitMix64) |
| `SceneEnvironment` / `CompositeSceneEnvironment` | Injection container (all-fakes by default) |
| `SceneBuilder` | `build(_ config:, env:) -> Entity`; `makeScene(…)` wraps in a `TestScene` |
| `TestScene(adopting:)` | Wrap a real builder's root for assertions |

### SceneSnapshot — structural diffing & tree dumps

Capture the entity graph as a value type for golden-file regression and pre/post
comparison:

```swift
let before = SceneSnapshot(scene.root)
viewModel.triggerExplosion()
XCTAssertSnapshotsMatch(SceneSnapshot(scene.root), baseline: before)   // fails with diff

print(before.tree)
/*
 root
 ├─ avatar  pos(0.00, 1.60, 0.00)
 └─ npc     pos(0.00, 0.00, -3.00)  group:8192
*/
```

---

## Assertion reference

### Spatial & component assertions

| Category | Assertions |
|----------|-----------|
| Position | `XCTAssertPosition(_:near:within:)`, `XCTAssertWorldPosition(_:equals:accuracy:)`, `XCTAssertDistance(_:to:lessThan:)` |
| Orientation | `XCTAssertFacing(_:towards:tolerance:)`, `XCTAssertUpright(_:tolerance:)` |
| Scale / sanity | `XCTAssertWorldScale(_:equals:accuracy:)`, `XCTAssertFiniteTransforms(_:)`, `XCTAssertUniformScale(_:equals:accuracy:)` |
| Components | `XCTAssertHasComponent`, `XCTAssertNoComponent`, `XCTAssertComponent(…satisfies:)`, `XCTAssertComponentCount` |
| Hierarchy | `XCTAssertChild(of:)`, `XCTAssertDescendant(of:)`, `XCTAssertEntityExists(named:)`, `XCTAssertNoEntity(named:)` |
| Collision | `XCTAssertColliderGroup(contains:)`, `XCTAssertColliderMask(contains:)`, `XCTAssertCollides(with:)`, `XCTAssertNoCollision(with:)`, `XCTAssertNoCollider(_:)` |

Angle tolerances use `Angle` (`.degrees(15)` / `.radians(_:)`) — no raw-radian pitfalls.
`XCTAssertCollides` reads `CollisionComponent.filter` (group ⊗ mask) so it verifies your
collision-group registry contract without running physics.

### Entity structure assertions

| Assertion | What it checks |
|-----------|---------------|
| `XCTAssertEntityName(_:_:)` | Resolves an optional entity and verifies its name |
| `XCTAssertChildCount(_:_:)` | Exact direct child count |
| `XCTAssertHasChildren(_:)` / `XCTAssertNoChildren(_:)` | At least one / zero children |
| `XCTAssertEnabled(_:)` / `XCTAssertDisabled(_:)` | `entity.isEnabled` |
| `XCTAssertSubtreeSize(_:equals:)` | Total entity count in subtree (including root) |
| `XCTAssertRoot(_:)` / `XCTAssertHasParent(_:)` | Presence / absence of a parent |

### Scene-state API

| Type | Purpose |
|------|---------|
| `SceneStateSpec` | Declarative expectations; call `.assert(against:)` |
| `SceneRequirement` | `Requires`, `Forbids`, `Expect`, `Requires(atLeast:)`, `Requires(exactly:)`, `Requires(atMost:)` |
| `EntityPredicate` | `.hasComponent(_:)`, `.named(_:)`, `.satisfies(_:_:)` |
| `SceneInvariantSet` / `SceneInvariant` | Per-frame invariants on the root entity |
| `SceneSnapshot` | Structural tree capture; `snap.tree`, `XCTAssertSnapshotsMatch` |
| `SystemHarness` | Drives simulation steps; `tick(frames:invariants:)`, `tickUntil` |
| `FrameClock` | Deterministic time; `deltaTime`, `advance(frames:)`, `reset()` |

---

## Roadmap

- ✅ **v1.2** Dependency-injection layer — provider protocols, scriptable fakes,
  `SceneEnvironment`, `SceneBuilder`, env-aware `SystemHarness`. See
  [docs/DEPENDENCY-INJECTION.md](docs/DEPENDENCY-INJECTION.md).
- ✅ **v1.3** `ImmersiveCaptureApp` — macOS capture tool: edit `Scene.swift`, run
  `swift run ImmersiveCaptureApp`, read the PNG. Captures a real `RealityView`-rendered
  scene. See [docs/RENDER-CAPTURE.md](docs/RENDER-CAPTURE.md).
- **Next** Record a real ARKit session on-device → replay deterministically in CI
  (provider protocols are the seam this plugs into).
