# Motion Testing — ImmersiveTesting v1.3

Spatial motion is the hardest part of an immersive scene to verify: entities warp to wrong positions, AI overshoots, and trajectories degrade silently. This guide covers all the motion-testing primitives added in v1.3.

---

## Overview

The motion layer adds four collaborating types to `ImmersiveTestingRuntime` (safe to use from your app target) and one set of XCTest assertions in `ImmersiveTesting` (test target only).

| Type | Where | Purpose |
|------|-------|---------|
| `MotionPath` | Runtime | Interpolatable pose sequence — the reference path |
| `PathRecorder` | Runtime | Captures entity pose every tick for comparison |
| `PathDrivenWorldTracking` | Runtime | Device walks a scripted path (WorldTrackingProviding) |
| `PathDrivenHands` | Runtime | Pointer tip follows a scripted path (HandTrackingProviding) |
| `EntityPathDriver` | Runtime | Drives any entity along a path as a SystemStep |
| `SpatialRegion` | Runtime | Named sphere/box/cylinder volume |
| Motion assertions | Test-only | `XCTAssertFollowsPath`, `XCTAssertMaxSpeed`, etc. |

---

## MotionPath — building reference paths

### Static factories

```swift
// Straight line
let straight = MotionPath.linear(from: [0, 1.6, 0], to: [10, 1.6, 0], duration: 5.0)

// Circular arc in the XZ plane (startAngle/endAngle in radians from +X)
let halfOrbit = MotionPath.arc(
    center: .zero, radius: 5,
    startAngle: 0, endAngle: .pi,
    height: 1.6, duration: 3.0
)

// Full circle
let orbit = MotionPath.circle(center: [0, 1.6, 0], radius: 3, duration: 4.0)

// Evenly-timed waypoints
let patrol = MotionPath.waypoints(
    [[0,0,0], [5,0,0], [5,0,5], [0,0,5]], duration: 4.0
)
```

### `@PathBuilder` DSL — "draw" a path from segments

Chain segments from a starting position. Each segment begins where the previous ended, so the path is always C0-continuous.

```swift
let route = MotionPath(from: [0, 0, 0]) {
    // Straight
    PathSegment.move(to: [8, 0, 0], duration: 2.0)

    // Circular arc around center [8,0,5], sweep 90° to toAngle = π/2
    // Start angle is inferred from current position relative to center.
    PathSegment.arc(center: [8, 0, 5], toAngle: .pi / 2,
                    radius: 5, duration: 1.5)

    // Quadratic Bézier curve — control point pulls the path upward
    PathSegment.curve(via: [4, 3, 8], to: [0, 0, 8], duration: 2.0)

    // Pause at the current position
    PathSegment.pause(duration: 0.5)

    // Back home
    PathSegment.move(to: [0, 0, 0], duration: 2.0)
}
```

#### `PathSegment.arc` — inferred start angle

The `arc` segment infers its starting angle from the current path position relative to `center`. This means you don't need to know the angle in advance — you only specify where you want to *end up* (`toAngle`). The arc will be continuous with the previous segment automatically.

```swift
// Entity is at [5, 0, 0]. Sweeping to toAngle = π/2 arcs it around
// to roughly [0, 0, 5] (center = origin, radius = 5).
PathSegment.arc(center: [0, 0, 0], toAngle: .pi / 2, radius: 5, duration: 2.0)
```

#### Path properties

```swift
route.duration          // total seconds
route.totalDistance     // arc length in metres
route.maxSpeed          // highest m/s between any two keyframes
route.averageSpeed      // totalDistance / duration
```

#### Sampling

```swift
let (pos, rot) = route.pose(at: 1.5)        // interpolated at 1.5s
let transform  = route.transform(at: 1.5)   // as RealityKit Transform
```

---

## PathRecorder — record entity trajectories

Attach to a `SystemHarness` as a step **after** all movement steps. Query `recordedPath` or `samples` once ticking is done.

```swift
let npc = scene["npc"]!
let recorder = PathRecorder(entity: npc, clock: harness.clock)

// Register LAST so all movement steps have run before we sample.
harness.registerStep("chase")  { … }
harness.registerStep("react")  { … }
harness.register(recorder.asStep())   // runs after the above

harness.tick(frames: 270)  // 3 seconds at 90 Hz

// Now assert:
XCTAssertMaxSpeed(recorder, lessThan: 5.0)
XCTAssertReachesPosition(recorder, position: objectivePos, within: 0.5)
XCTAssertPathLength(recorder, approximately: 12.0, within: 1.0)
```

> **Note:** `PathRecorder` captures `entity.orientation` (local-space). For entities with
> non-trivial parents, compute world orientation from `transformMatrix(relativeTo: nil)` yourself.

---

## PathDrivenWorldTracking — scripted device pose

Instead of updating `FakeWorldTracking.position` every frame, use a `PathDrivenWorldTracking` so the device "walks" a pre-built path automatically. **Share the clock** — pass the same `FrameClock` to the harness and to this provider.

```swift
let devicePath = MotionPath(from: [0, 1.6, 0]) {
    PathSegment.move(to: [10, 1.6, 0], duration: 5.0)
    PathSegment.arc(center: [10, 1.6, 10], toAngle: .pi, radius: 10, duration: 6.0)
}
let clock = FrameClock()
let worldTracking = PathDrivenWorldTracking(path: devicePath, clock: clock)
let env = CompositeSceneEnvironment(worldTracking: worldTracking)
let harness = SystemHarness(scene: scene, clock: clock, environment: env)

// Any step reading env.worldTracking.devicePosition() sees the device
// automatically walking the devicePath as ticks advance.
harness.registerStep("chase") { entities, dt, env in
    let target = env.worldTracking.devicePosition()
    …
}
harness.tick(frames: 990)  // 11 seconds
```

---

## PathDrivenHands — scripted pointer-tip sweep

Use to test interaction systems without manually updating `ScriptedHands.pointerTip` each frame. Only the pointer-tip position follows the path; pinch distances stay fixed (mutate them to trigger interactions at specific moments).

```swift
let aimSweep = MotionPath.arc(
    center: [0, 1.5, -4], radius: 1.5,
    startAngle: -.pi / 3, endAngle: .pi / 3,
    height: 1.5, duration: 2.0
)
let clock = FrameClock()
let hands = PathDrivenHands(pointerPath: aimSweep, clock: clock)
hands.rightPinchDistance = 0.04  // pinch closed → interaction active

let env = CompositeSceneEnvironment(hands: hands)
let harness = SystemHarness(scene: scene, clock: clock, environment: env)
```

---

## EntityPathDriver — drive NPCs along a path

Drives any entity's `position` (and optionally `orientation`) along a `MotionPath` as a `SystemStep`. Ideal for deterministic NPC routing in tests.

```swift
let patrolRoute = MotionPath.waypoints(
    [[0,0,0],[8,0,0],[8,0,8],[0,0,8]], duration: 4.0
)
let clock = FrameClock()
let driver = EntityPathDriver(entity: npc, path: patrolRoute, clock: clock)

// Register the driver FIRST so reaction steps see the updated position.
harness.register(driver.asStep())
harness.registerStep("react") { … }
let recorder = PathRecorder(entity: npc, clock: clock)
harness.register(recorder.asStep())
```

Set `applyRotation = true` if your path has meaningful orientation keyframes (e.g. built from explicit `PathKeyframe` arrays).

---

## SpatialRegion — named volumes for containment

```swift
let arena    = SpatialRegion.sphere(center: .zero, radius: 10, name: "arena")
let spawnBox = SpatialRegion.box(center: [0,0,0], size: [6,3,6], name: "spawn zone")
let column   = SpatialRegion.cylinder(center: .zero, radius: 5,
                                       halfHeight: .infinity, name: "XZ circle")

// Point check
arena.contains(npc.position(relativeTo: nil))

// All-points check
arena.containsAll(positions)

// Which points are outside?
let escapes = arena.violations(in: positions)
```

---

## Motion Assertions (test-target only)

Import `ImmersiveTesting` to access these.

### `XCTAssertFollowsPath`

The primary assertion: entity followed a reference path within a tolerance at each keyframe time.

```swift
let expected = MotionPath.linear(from: [0,0,0], to: [10,0,0], duration: 5.0)
XCTAssertFollowsPath(recorder, matches: expected, within: 0.15)
```

### `XCTAssertMaxSpeed`

No teleporting / illegal position jumps between consecutive frames.

```swift
XCTAssertMaxSpeed(recorder, lessThan: 5.0)   // m/s
```

### `XCTAssertSmoothMotion`

Delta-V per frame stays below the limit — catches overshooting controllers, missing easing, or sudden target teleports that cause an abrupt change in pursuit speed.

```swift
XCTAssertSmoothMotion(recorder, maxSpeedChangePerFrame: 0.3)
```

### `XCTAssertReachesPosition`

Entity came within `tolerance` of the target at some point during the simulation.

```swift
XCTAssertReachesPosition(recorder, position: exitDoor.position, within: 0.5)
```

### `XCTAssertPathLength`

Total distance travelled matches expectation (within tolerance).

```swift
XCTAssertPathLength(recorder, approximately: 12.0, within: 0.5)
```

### `XCTAssertEntity(_:within:)` and `XCTAssertAllEntities(_:in:within:)`

Single entity or all entities of a component type lie inside a `SpatialRegion`.

```swift
let arena = SpatialRegion.sphere(center: .zero, radius: 10, name: "arena")
XCTAssertEntity(npc, within: arena)
XCTAssertAllEntities(NPCComponent.self, in: scene.root, within: arena)
```

---

## SceneInvariant extensions

Check spatial constraints every simulated frame via `SceneInvariantSet`:

```swift
let arena = SpatialRegion.sphere(center: .zero, radius: 10, name: "arena")

let invariants = SceneInvariantSet {
    SceneInvariant.noNaNTransforms
    SceneInvariant.aboveFloor(minY: -0.05)   // small tolerance
    SceneInvariant.withinRegion("npcs in arena", region: arena) { root in
        root.entities(with: NPCComponent.self)
    }
    SceneInvariant.component(NPCComponent.self, staysWithin: arena)
}

harness.tick(frames: 600, invariants: invariants)
// Test fails on the exact frame an invariant is first violated.
```

---

## Complete example: NPC chases a walking device

```swift
@MainActor
func testNPCChasesWalkingDevice() {
    // Device walks a straight path, then curves around a corner.
    let devicePath = MotionPath(from: [0, 1.6, 0]) {
        PathSegment.move(to: [8, 1.6, 0], duration: 4.0)
        PathSegment.arc(center: [8, 1.6, 5], toAngle: .pi / 2,
                        radius: 5, duration: 3.0)
    }

    let clock = FrameClock()
    let worldTracking = PathDrivenWorldTracking(path: devicePath, clock: clock)
    let env = CompositeSceneEnvironment(worldTracking: worldTracking)

    let npc = Entity("npc")
    npc.position = [0, 0, 0]
    let scene = TestScene { npc }

    let recorder = PathRecorder(entity: npc, clock: clock)
    let harness = SystemHarness(scene: scene, clock: clock, environment: env)
    let arena = SpatialRegion.box(center: [6, 0, 3], size: [20, 5, 20], name: "level")

    harness.registerStep("chase") { entities, dt, env in
        let target = env.worldTracking.devicePosition()
        for e in entities where e.name == "npc" {
            let dir = target - e.position
            guard length(dir) > 0.05 else { continue }
            e.position += normalize(dir) * 2.5 * dt   // 2.5 m/s
        }
    }
    harness.register(recorder.asStep())

    harness.tick(frames: 630, invariants: SceneInvariantSet {   // 7 seconds
        SceneInvariant.noNaNTransforms
        SceneInvariant.aboveFloor(minY: -0.1)
    })

    // NPC kept up with the device.
    XCTAssertGreaterThan(npc.position.x, 5.0)
    XCTAssertMaxSpeed(recorder, lessThan: 3.0)
    XCTAssertSmoothMotion(recorder, maxSpeedChangePerFrame: 0.5)
    XCTAssertEntity(npc, within: arena)
}
```

---

## API changes from v1.2 → v1.3

- **`SystemStep` moved to `ImmersiveTestingRuntime`** (was in `ImmersiveTesting`).
  All existing call sites compile unchanged. The type is now available to app-target code and
  to `PathRecorder`/`EntityPathDriver`.
- No other breaking changes; the full Tier1/Tier2/Tier3 suite continues to pass.
