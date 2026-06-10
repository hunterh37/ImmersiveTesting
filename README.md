# ImmersiveTesting

A test framework for immersive visionOS / RealityKit apps — built so that **coding agents
can verify and fix spatial 3D code without a headset**. It gives an agent two things it
otherwise can't have: a way to *assert* on a RealityKit scene headlessly, and a way to
*see* one.

**1. Agents can snapshot RealityKit code and look at it.** Edit one `Scene.swift`, run
`swift run ImmersiveCaptureApp`, and get back a fully rendered PNG of the RealityView
scene — entities, materials, lighting and all. The agent reads the image and iterates
inside an agentic loop instead of editing 3D code blind.
See [docs/RENDER-CAPTURE.md](docs/RENDER-CAPTURE.md).

**2. Headless, deterministic scene testing on macOS CI.** RealityKit entities instantiate
fine in a plain `XCTest`, so you assert against the same entity graph the app holds at
runtime: spatial assertions, a scene-builder DSL, deterministic ECS simulation, and
declarative scene-state specs — no simulator, no device.

**3. An architecture that makes immersive code testable at all.** Scene logic is usually
tangled into the `RealityView` closure and reaches for `.shared` singletons and live ARKit.
ImmersiveTesting is designed around a layered architecture (thin view shell → `SceneBuilder`
+ ECS systems → provider-protocol services) where runtime dependencies are injected through
a `SceneEnvironment`. This is the foundation the other two features rely on — see the
[architecture guide](#architecture-guide--testable-visionos-games) below.

> Built on the insight that the entity graph constructs identically in a headless `XCTest`
> and on-device, so logic verified in CI is the logic that ships.

For gotchas (`@MainActor` everywhere, hostless vs hosted test bundles, the immersive-app
sim-shell crash, name-lookup rules) see [docs/VISIONOS-TESTING-NOTES.md](docs/VISIONOS-TESTING-NOTES.md).

## Install

```swift
.package(path: "../ImmersiveTesting")  // local
// or
.package(url: "https://github.com/hunterh37/ImmersiveTesting.git", from: "1.3.0")
```

---

## Architecture guide — testable visionOS games

Structure the app in three layers; everything above the services line must be
constructible on macOS without a headset.

```
┌─────────────────────────────────────────────────────────┐
│  SwiftUI / ImmersiveView  (thin shell — no logic)       │
│  • creates the SceneEnvironment with live adapters      │
│  • calls SceneBuilder.makeScene(config:env:)            │
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
| Systems expose `static step(entities:dt:env:)` | `SceneUpdateContext` has no public init — you can't call `update(context:)` from a test |
| All `.shared` / ARKit calls live in `Live*` adapters | one seam per service — swap for a fake in tests |
| `ViewModel` receives env via init, defaults to `.fake()` | `GameViewModel()` in a test needs zero setup |
| Tests use `SeededRandom` | layout failures replay byte-for-byte; no flakes |
| Test suite runs hostless on macOS | no simulator required, fast CI |

For the full DI API reference see [docs/DEPENDENCY-INJECTION.md](docs/DEPENDENCY-INJECTION.md).

---

## Core APIs

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
