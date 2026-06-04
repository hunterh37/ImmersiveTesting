# visionOS / RealityKit testing — gotchas & decisions

Hard-won notes from building ImmersiveTesting and wiring it into a real visionOS game
(ZombieShooter). These are the non-obvious things that cost time; bake them in so the next
person (or agent) doesn't re-discover them.

---

## 1. Everything that touches `Entity` is `@MainActor` (Swift 6)

RealityKit's `Entity`, `Component` accessors, `children`, `findEntity`, `name`,
`addChild`, etc. are all `@MainActor`-isolated. Under Swift 6 strict concurrency this is
enforced, so:

- **Every assertion and helper that reads an `Entity` is annotated `@MainActor`** in this
  package. If you add a new assertion, annotate it too or it won't compile against an
  isolated `Entity`.
- **Consumer test classes must be `@MainActor`:**
  ```swift
  @MainActor
  final class SurvivalModeTests: XCTestCase { … }
  ```
  Without it you get `main actor-isolated … can not be referenced from a nonisolated
  context` errors on every assertion call. This is expected and correct — not a bug to
  work around.

## 2. The result-builder block takes `[Entity]...`, not `Entity...`

The `@EntityBuilder` DSL builds each expression into `[Entity]` (so `buildOptional` /
`buildArray` / `if` work). Therefore `buildBlock` must be:
```swift
static func buildBlock(_ components: [Entity]...) -> [Entity] { components.flatMap { $0 } }
```
Using `Entity...` fails with *"cannot pass array of type '[Entity]' as variadic arguments
of type 'Entity'"* once a block has more than one statement.

## 3. Name lookup: exact match wins before dotted-path parsing

`TestScene`'s `subscript(_:)` splits on `.` to walk a path (`"gun.gunTip"`). But entities
whose **own name contains a dot** (e.g. `"zombie_0.head"`) would be mis-parsed as a path
and not found.

Resolution order (see `TestScene.swift`):
1. `root.name == path` → root
2. exact `findEntity(named: path)` anywhere in the subtree → that entity
3. fall back to dotted-path walk: first segment resolved anywhere, later segments walked
   strictly through child names

Use `scene.entity(atPath:)` to **force** path semantics and ignore exact-name matches.
Regression test: `testLookupHandlesLiteralDotInName`.

> Practical takeaway for fixtures: prefer plain child names (`"head"`, `"torso"`) and let
> the path walk (`scene["zombie_0.head"]`) compose them. Reserve dotted *names* for cases
> where the entity genuinely needs a qualified identity.

## 4. ⚠️ The biggest one: hosting an immersive app in a unit-test bundle is fragile

A visionOS unit-test bundle is normally injected into a **TEST_HOST** app, which the
simulator launches before running tests. For an immersive RealityKit app this is risky:

- Launching ZombieShooter under test injection **crashed the simulator system shell**
  (`SurfBoard … probably crashed`, `FBSOpenApplicationServiceErrorDomain Code=5`), so the
  test bundle never loaded and `0` tests ran — even though the code compiled fine.
- Immersive apps also pull in GameKit auth, ARKit/`ImmersiveSpace`, spatial-audio setup on
  launch — all of which misbehave or spew errors in the simulator.

### Two valid configurations — choose deliberately

| Mode | `project.yml` | Buys you | Costs |
|------|---------------|----------|-------|
| **Hostless logic-test** | no app-target dep, no `TEST_HOST` | rock-solid, fast, never launches the immersive app | **cannot** `@testable import` the game — package + RealityKit only |
| **Hosted** | `TEST_HOST` + `BUNDLE_LOADER` set to the app, depend on the app target | `@testable import ZombieShooter` to drive real components/managers | risks the sim-shell launch crash above; slower; noisy logs |

The package's *own* tests run hostless on macOS (fastest). For the game, the survival
**scene-contract** suite works perfectly hostless because it only needs ImmersiveTesting +
RealityKit. Switch to the hosted config **only** when a test genuinely needs to
`@testable import` the game target — and expect to babysit simulator flakiness.

### Required regardless: generate an Info.plist

The test target needs `GENERATE_INFOPLIST_FILE: YES`, or the build fails with
*"target does not have an Info.plist file … Apply an Info.plist or set
GENERATE_INFOPLIST_FILE"*.

## 5. Running the tests reliably

- Parallel testing clones simulators and **splits the suite across workers**, so a single
  console shows e.g. `Executed 3 tests` per clone — the *sum* is your real count, not each
  line. Don't panic at a partial-looking number.
- `test-without-building` happily reuses a **stale/cleaned bundle** and fails to load it.
  When in doubt, run a full `xcodebuild test` (build + run), not `test-without-building`.
- Filter noise: GameKit / `gamed` / SpatialAudio / `nw_socket` errors in the log are
  simulator noise, not test failures. Grep for `Test Case .* (passed|failed)` and the
  final `TEST SUCCEEDED|FAILED` verdict.

## 6. The scene-contract pattern (how the game suite is structured)

Deep game state (singletons + live ARKit + a long-lived `Scene`) isn't unit-testable
without refactoring. Instead the suite tests the **scene-configuration contract**:

- A fixture (`SurvivalScene.make(Config)`) builds the entity graph a given game state is
  supposed to produce, using the ImmersiveTesting DSL and local stand-in components that
  mirror the game's contracts (collision groups, tags, hierarchy).
- Tests assert that contract (presence, hierarchy, spatial bands, collision filters,
  state transitions) — fast, deterministic, headless.
- **One documented swap point:** when `WaveManager`/`ImmersiveView` expose a buildable
  root, point `make` at the real builder and the same assertions keep working — at which
  point you flip to the hosted config (§4) for `@testable import`.

This is the recommended way to test immersive scenes today: pin the *contract*, not the
running app.

---

## 7. Dependency injection — making the swap point real (v1.2)

§6's "swap point" was previously impossible to flip: the real builders depend on
`WorldTrackingManager.shared`, `SceneReconstructionManager.shared`, live hand tracking, and
`SceneUpdateContext` — none constructible headlessly. v1.2 adds the seam that fixes this.
Full guide: **`DEPENDENCY-INJECTION.md`**. Hard-won points specific to this package:

- **The environment must NOT own a clock.** `SystemHarness` is the single time source
  (`FrameClock`). An early design put a clock on `SceneEnvironment` too — two clocks drift and
  you get non-deterministic ticks. Env = the four *providers* only.
- **Keep ARKit out of the providers.** Every requirement is a RealityKit/simd value type
  (`Transform`, `SIMD3`). If you express a provider in terms of `DeviceAnchor`/`HandAnchor`
  the package stops building on macOS CI. The *app* bridges ARKit in its `Live*` adapters.
- **Additive only on `SystemHarness`.** `SystemStep` got an env-aware initializer plus a
  back-compat one that drops the env; `init`/`registerStep` env params are defaulted. This is
  why all 49 pre-v1.2 tests still pass without edits — verify this when touching the harness.
- **Determinism needs a real PRNG, not `Float.random`.** `SeededRandom` is SplitMix64 with a
  24-bit mantissa extraction (top bits → exact float in `[0,1)`). Same seed ⇒ byte-identical
  `SceneSnapshot` across runs/machines, so a "random layout" failure replays exactly.
- **Flip order:** conform real managers via `Live*` adapters → extract a `SceneBuilder` →
  default its `env` param to a live environment (production unchanged) → repoint
  `SurvivalScene.make` at the real builder and delete the stand-in components. Only the last
  step forces the hosted config (§4).
