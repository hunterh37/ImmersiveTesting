# ImmersiveTesting

Unit-test immersive visionOS / RealityKit content **without a headset**. Spatial
assertions, a headless scene-builder DSL, deterministic ECS system simulation, and
declarative scene-state verification for `ImmersiveView`-style scenes.

> Built on the insight that `Entity`, `Transform`, and most `Component`s instantiate fine
> in a plain `XCTest` — so the entity graph you assert against is exactly what RealityKit
> holds at runtime. Runs on macOS CI for fast logic tests.

To visually inspect a RealityKit scene, see **[docs/RENDER-CAPTURE.md](docs/RENDER-CAPTURE.md)** —
edit one file, run one command, get a PNG.

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

## Architecture guide — testable visionOS games

This section explains how to structure a visionOS RealityKit game so every layer is
independently testable headlessly on macOS CI. The patterns below are what ImmersiveTesting
is designed around; adopting them is what makes the assertion and simulation APIs pay off.

### The three-layer model

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
layer and gets hidden behind a provider protocol. Everything above that line must be
constructible on macOS without a headset.

---

### 1. Keep ImmersiveView as a thin shell

`ImmersiveView` / `RealityView` should do nothing except wire the layers together. All
logic, all state, all entity construction lives elsewhere.

```swift
// ✅ Good — ImmersiveView is a thin shell
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

// ❌ Bad — business logic + singleton calls directly in the view
struct GameImmersiveView: View {
    var body: some View {
        RealityView { content in
            let pos = WorldTrackingManager.shared.getOriginFromDeviceTransform()
            let npc = Entity("npc")
            npc.position = pos + SIMD3(Float.random(in: -3...3), 0, -3)
            content.add(npc)
        }
    }
}
```

---

### 2. Extract scene construction into a `SceneBuilder`

A `SceneBuilder` is a pure function: given a config value and a `SceneEnvironment`, it
returns an entity graph. No singleton access, no `ARKit` imports, no stored mutable state.

```swift
struct GameSceneBuilder: SceneBuilder {
    struct Config {
        var round: Int
        var npcCount: Int
        var difficulty: Difficulty
    }

    func build(_ config: Config, env: any SceneEnvironment) -> Entity {
        let root = Entity("sceneRoot")

        // ✅ All runtime-dependent reads go through env
        let devicePos = env.worldTracking.devicePosition()

        let avatar = Entity("avatar")
        avatar.position = devicePos + SIMD3(0, 0, -1.5)
        avatar.components.set(VitalComponent(lives: 3))
        root.addChild(avatar)

        for i in 0..<config.npcCount {
            // ✅ Seeded random → deterministic in tests, different each run in production
            let offset = env.random.unitVectorXZ() * Float(3 + config.difficulty.spawnRadius)
            let npc = Entity("npc_\(i)")
            npc.position = devicePos + offset
            npc.components.set(NPCTag())
            npc.components.set(NPCAIComponent(target: avatar))
            root.addChild(npc)
        }

        return root
    }
}
```

Because `build` is pure, the test just provides a fake environment and asserts the graph:

```swift
@MainActor
func testRoundOneSpawnsCorrectNPCCount() {
    let env = CompositeSceneEnvironment(random: SeededRandom(seed: 1))
    let scene = GameSceneBuilder().makeScene(.init(round: 1, npcCount: 5, difficulty: .normal), env: env)

    SceneStateSpec("round-1") {
        Requires(exactly: 5, matching: .hasComponent(NPCTag.self))
        Requires(entityNamed: "avatar")
        Requires(atLeast: 1, matching: .hasComponent(NPCAIComponent.self))
    }.assert(against: scene.root)
}
```

---

### 3. Extract system logic into static methods

RealityKit `System.update(context:)` is not constructible headlessly. Extract the logic into
a static function that your real `System` delegates to. The static function is what you
register with `SystemHarness` in tests.

```swift
// In your app target:
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
            let direction = normalize(target - npc.position)
            npc.position += direction * ai.speed * dt
        }
    }
}

// In your test target:
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

    // All NPCs moved toward x=5
    for npc in scene.root.children where npc.components[NPCTag.self] != nil {
        XCTAssertLessThan(npc.position.x, 5)
    }
}
```

---

### 4. Hide singleton / ARKit calls behind provider protocols

Every call to a `.shared` singleton or ARKit type is a seam that blocks testing. Wrap them
in the provider protocols so tests can substitute a fake.

```swift
// In your app — thin adapters over the real managers:
final class LiveWorldTracking: WorldTrackingProviding {
    func devicePosition() -> SIMD3<Float> {
        guard let t = WorldTrackingManager.shared.getOriginFromDeviceTransform() else {
            return .zero
        }
        return t.columns.3.xyz
    }
    func deviceTransform() -> simd_float4x4 {
        WorldTrackingManager.shared.getOriginFromDeviceTransform() ?? .init(diagonal: .one)
    }
}

final class LiveSceneEffects: SceneEffectsProviding {
    func startEffect(named name: String) {
        SceneReconstructionManager.shared.startEffect(named: name)
    }
    func stopEffect(named name: String) {
        SceneReconstructionManager.shared.stopEffect(named: name)
    }
}

final class LiveHands: HandTrackingProviding {
    var leftPinchDistance: Float  { HandGestureModel.shared.leftPinchDistance }
    var rightPinchDistance: Float { HandGestureModel.shared.rightPinchDistance }
    var rightPointerTip: simd_float4x4? { HandGestureModel.shared.rightPointerTip }
}
```

Production builds wire the live adapters once, at the `ImmersiveView` layer:

```swift
// Singleton for production — never accessed in builders or systems directly
extension GameEnvironment {
    static let live = CompositeSceneEnvironment(
        worldTracking: LiveWorldTracking(),
        sceneEffects:  LiveSceneEffects(),
        hands:         LiveHands()
    )
}
```

---

### 5. Use `ViewModel` for state transitions, not layout

`ViewModel` owns the game-state machine (menus, round progression, pause, game-over). It
operates on the *root entity* it was handed — it doesn't construct the scene itself.

```swift
@MainActor
final class GameViewModel: ObservableObject {
    @Published var state: GameState = .menu
    var sceneRoot: Entity?

    func startRound(_ config: GameSceneBuilder.Config) {
        state = .playing(round: config.round)
        sceneRoot?.findEntity(named: "mainMenuPanel")?.isEnabled = false
        sceneRoot?.findEntity(named: "objectiveAnchor")?.isEnabled = true
        // Trigger effects through the environment, not a singleton:
        env.sceneEffects.startEffect(named: "roundStart")
    }

    private let env: any SceneEnvironment

    init(env: any SceneEnvironment = .fake()) {
        self.env = env        // ✅ default to fake so test init needs no arguments
    }
}
```

Testing state transitions needs only a `TestScene` and the fake environment:

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
    XCTAssertEnabled(scene["objectiveAnchor"]!)
}
```

---

### 6. Test file layout

```
MyGame/
├── Sources/
│   └── MyGame/
│       ├── Views/
│       │   └── GameImmersiveView.swift      ← thin shell only
│       ├── Scene/
│       │   ├── GameSceneBuilder.swift       ← SceneBuilder conformance
│       │   ├── NPCAISystem.swift            ← System + static step(...)
│       │   └── Components/
│       │       ├── NPCTag.swift
│       │       └── VitalComponent.swift
│       ├── ViewModel/
│       │   └── GameViewModel.swift          ← state machine
│       └── Services/
│           ├── LiveWorldTracking.swift      ← adapters over .shared
│           ├── LiveSceneEffects.swift
│           └── LiveHands.swift
└── Tests/
    └── MyGameTests/
        ├── SceneBuilderTests.swift          ← entity graph shape & count
        ├── SystemTests.swift               ← per-frame simulation
        ├── ViewModelTests.swift            ← state transition assertions
        └── InvariantTests.swift            ← frame-level invariants
```

---

### Best practices at a glance

| Rule | Why |
|------|-----|
| `ImmersiveView` creates the env + calls `makeScene` — nothing else | keeps the shell replaceable without touching logic |
| `SceneBuilder.build` is a pure `(Config, env) → Entity` | makes the builder unit-testable headlessly |
| Systems expose `static step(entities:dt:env:)` | decouples logic from `SceneUpdateContext` |
| All `.shared` / ARKit calls live in `Live*` adapters | one seam per service — swap for a fake in tests |
| `ViewModel` receives env via init, defaults to `.fake()` | `GameViewModel()` in a test needs zero setup |
| Tests use `SeededRandom` | layout failures replay byte-for-byte; no flakes |
| Test suite runs hostless on macOS | no simulator required, fast CI |

For the full DI API reference see **[docs/DEPENDENCY-INJECTION.md](docs/DEPENDENCY-INJECTION.md)**.
For `@MainActor` gotchas, hostless vs hosted test bundles, and simulator crash avoidance see
**[docs/VISIONOS-TESTING-NOTES.md](docs/VISIONOS-TESTING-NOTES.md)**.

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

`SystemHarness` gained an `environment` and an env-aware `registerStep` overload; the old
`(entities, dt)` overload is unchanged, so existing tests keep compiling.

## v1.1 — what's new

### SceneStateSpec — declarative scene-state assertions

The headline feature. Describe what the entity graph *must* look like in a given app state,
then assert it after the state transition. One spec call gives you a rich pass/fail summary
listing every requirement, not just the first failure.

```swift
@MainActor
final class RoundTests: XCTestCase {

    func testStartingRoundConfiguresScene() {
        let scene = TestScene {
            Entity("avatar").position(0, 1.6, 0).component(VitalComponent(lives: 3))
        }
        let vm = ViewModel(scene: scene.root)
        vm.startRound()

        SceneStateSpec("roundActive") {
            Requires(entityNamed: "objectiveAnchor")
            Requires(atLeast: 1, matching: .hasComponent(NPCAIComponent.self))
            Requires(exactly: 1, matching: .named("avatar"))
            Forbids(entityNamed: "mainMenuPanel")
            Expect(entityNamed: "avatar", "lives == 3") { entity in
                entity.components[VitalComponent.self]?.lives == 3
            }
        }.assert(against: scene.root)
    }
}
```

**Failure output:**
```
SceneStateSpec "roundActive" failed (2 violations):
  ✗ requires entity "objectiveAnchor"                    — not found
  ✗ forbids entity "mainMenuPanel"                      — present at /root/ui/mainMenuPanel
  ✓ at least 1 has NPCAIComponent                      — found 3
  ✓ exactly 1 named "avatar"                            — found 1
  ✓ avatar: lives == 3                                  — ✓
```

### SceneInvariantSet — frame-level invariants

Conditions that must hold *every frame* of simulation. Pass to `SystemHarness.tick` to fail
on the exact frame a property breaks, not after the run completes.

```swift
let invariants = SceneInvariantSet {
    SceneInvariant.noNaNTransforms
    SceneInvariant.alwaysPresent(named: "avatar")
    SceneInvariant.neverPresent(named: "mainMenuPanel")
    SceneInvariant.cap(ProjectileComponent.self, atMost: 50)
    SceneInvariant("avatar never below floor") { root in
        (root.findEntity(named: "avatar")?.worldPosition.y ?? 0) > -0.1
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
 ├─ avatar  pos(0.00, 1.60, 0.00)
 └─ npc     pos(0.00, 0.00, -3.00)  group:8192
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

Angle tolerances use `Angle` (`.degrees(15)` / `.radians(_:)`) — no raw-radian pitfalls.
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
- ✅ **v1.3** `ImmersiveCaptureApp` — macOS capture tool: edit `Scene.swift`, run
  `swift run ImmersiveCaptureApp`, read the PNG. Real Metal rendering via ScreenCaptureKit.
  See [docs/RENDER-CAPTURE.md](docs/RENDER-CAPTURE.md).
