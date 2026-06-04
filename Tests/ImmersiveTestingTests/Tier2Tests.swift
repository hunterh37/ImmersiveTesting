import XCTest
import RealityKit
import simd
@testable import ImmersiveTesting

// MARK: - FrameClockTests

@MainActor
final class FrameClockTests: XCTestCase {

    func testDefaultDeltaTimeIs90Hz() {
        let clock = FrameClock()
        XCTAssertEqual(clock.deltaTime, 1.0 / 90.0, accuracy: 1e-10)
    }

    func testAdvancingOneFrameIncrementsCounters() {
        let clock = FrameClock()
        clock.tick()
        XCTAssertEqual(clock.frame, 1)
        XCTAssertEqual(clock.time, 1.0 / 90.0, accuracy: 1e-10)
    }

    func testAdvancingMultipleFrames() {
        let clock = FrameClock()
        clock.advance(frames: 90)
        XCTAssertEqual(clock.frame, 90)
        XCTAssertEqual(clock.time, 1.0, accuracy: 0.0001)   // 1 second
    }

    func testResetClearsCounters() {
        let clock = FrameClock()
        clock.advance(frames: 30)
        clock.reset()
        XCTAssertEqual(clock.frame, 0)
        XCTAssertEqual(clock.time, 0)
    }

    func testCustomDeltaTime() {
        let clock = FrameClock(deltaTime: 1.0 / 60.0)
        clock.advance(frames: 60)
        XCTAssertEqual(clock.time, 1.0, accuracy: 0.0001)
    }

    func testDtPropertyMatchesDeltaTime() {
        let clock = FrameClock(deltaTime: 1.0 / 90.0)
        XCTAssertEqual(clock.dt, Float(1.0 / 90.0), accuracy: 1e-6)
    }

    func testTickWithCustomDeltaTime() {
        let clock = FrameClock()
        clock.tick(deltaTime: 0.5)   // hiccup frame
        XCTAssertEqual(clock.frame, 1)
        XCTAssertEqual(clock.time, 0.5, accuracy: 1e-10)
    }
}

// MARK: - SystemHarnessTests

@MainActor
final class SystemHarnessTests: XCTestCase {

    private func makeScene() -> TestScene {
        TestScene {
            Entity("projectile")
                .position(0, 1.5, 0)
                .component(ProjectileComponent(velocity: [0, 0, -10]))
        }
    }

    func testSimpleMotionStep() {
        let scene = makeScene()
        let harness = SystemHarness(scene: scene)

        harness.registerStep("motion") { entities, dt in
            for e in entities {
                guard var proj = e.components[ProjectileComponent.self] else { continue }
                guard !proj.hitRegistered else { continue }
                e.position = e.position + proj.velocity * dt
            }
        }

        harness.tick(frames: 90)  // 1 second at 90 Hz

        let projectile = scene["projectile"]!
        // 10 m/s for 1 second → z = -10
        XCTAssertEqual(projectile.position.z, -10, accuracy: 0.05)
    }

    func testHarnessClockAdvances() {
        let scene = makeScene()
        let harness = SystemHarness(scene: scene)
        harness.registerStep("noop") { _, _ in }
        harness.tick(frames: 45)
        XCTAssertEqual(harness.clock.frame, 45)
        XCTAssertEqual(harness.clock.time, 45.0 / 90.0, accuracy: 0.001)
    }

    func testTickUntilSucceeds() {
        let scene = TestScene {
            Entity("goal").position(0, 1.5, 0)
                .component(ProjectileComponent(velocity: [0, 0, -1]))
        }
        let harness = SystemHarness(scene: scene)
        harness.registerStep("move") { entities, dt in
            for e in entities {
                guard let proj = e.components[ProjectileComponent.self] else { continue }
                e.position = e.position + proj.velocity * dt
            }
        }

        // Wait until goal.z < -0.5 (takes ~45+ frames at 1 m/s)
        let goal = scene["goal"]!
        let frameReached = harness.tickUntil("z < -0.5", maxFrames: 200) {
            goal.position.z < -0.5
        }
        XCTAssertLessThan(frameReached, 200, "condition should have been met before max frames")
        XCTAssertLessThan(goal.position.z, -0.5)
    }

    func testClockFrameMatchesTickCount() {
        // Verifies the clock accurately tracks frames across multiple tick calls.
        let scene = TestScene { Entity("anchor") }
        let harness = SystemHarness(scene: scene)
        harness.registerStep("noop") { _, _ in }

        harness.tick(frames: 10)
        XCTAssertEqual(harness.clock.frame, 10)

        harness.tick(frames: 5)
        XCTAssertEqual(harness.clock.frame, 15)

        harness.clock.reset()
        XCTAssertEqual(harness.clock.frame, 0)
    }

    func testInvariantFiresOnViolation() {
        let scene = TestScene {
            Entity("p").component(ProjectileComponent(velocity: [0, 0, 0]))
        }
        let harness = SystemHarness(scene: scene)

        // Invariant: projectile count must stay ≤ 5. We'll exceed it manually.
        let invariants = SceneInvariantSet {
            SceneInvariant.cap(ProjectileComponent.self, atMost: 5)
        }

        // Add 6 projectiles
        for i in 0..<6 {
            scene.root.addChild(Entity("extra_\(i)").component(ProjectileComponent(velocity: .zero)))
        }

        let violations = invariants.violations(in: scene.root)
        XCTAssertFalse(violations.isEmpty, "invariant should fire with 7 projectiles > 5")
    }
}

// MARK: - SceneStateSpecTests

@MainActor
final class SceneStateSpecTests: XCTestCase {

    private func makeWaveScene(includeMenu: Bool = false, zombieCount: Int = 3) -> TestScene {
        TestScene {
            Entity("player").position(0, 1.6, 0).component(HealthComponent(lives: 3))
            Entity("waveController").component(WaveComponent(index: 1, aliveCount: zombieCount))
            for i in 0..<zombieCount {
                Entity("zombie_\(i)").component(ZombieAIComponent(state: .chasing))
            }
            if includeMenu { Entity("mainMenuPanel") }
        }
    }

    func testSpecPassesOnCorrectScene() {
        let scene = makeWaveScene()

        // Should produce zero violations
        let spec = SceneStateSpec("waveActive") {
            Requires(entityNamed: "player")
            Requires(entityNamed: "waveController")
            Requires(atLeast: 1, matching: .hasComponent(ZombieAIComponent.self))
            Forbids(entityNamed: "mainMenuPanel")
            Expect(entityNamed: "player", "lives == 3") { $0.components[HealthComponent.self]?.lives == 3 }
        }

        let violations = spec.violations(against: scene.root)
        XCTAssertTrue(violations.isEmpty, "Expected no violations. Got: \(violations)")
    }

    func testSpecCatchesMissingEntity() {
        let scene = TestScene { Entity("player") }

        let spec = SceneStateSpec("waveActive") {
            Requires(entityNamed: "objectiveAnchor")   // absent
        }

        let violations = spec.violations(against: scene.root)
        XCTAssertEqual(violations.count, 1)
        XCTAssertTrue(violations[0].contains("objectiveAnchor"))
    }

    func testSpecCatchesForbiddenEntity() {
        let scene = makeWaveScene(includeMenu: true)

        let spec = SceneStateSpec("waveActive") {
            Forbids(entityNamed: "mainMenuPanel")
        }

        let violations = spec.violations(against: scene.root)
        XCTAssertEqual(violations.count, 1, "mainMenuPanel must be caught as violation")
    }

    func testSpecCountingAtLeast() {
        let scene = makeWaveScene(zombieCount: 0)  // no zombies

        let spec = SceneStateSpec("needsZombies") {
            Requires(atLeast: 1, matching: .hasComponent(ZombieAIComponent.self))
        }

        XCTAssertFalse(spec.violations(against: scene.root).isEmpty)
    }

    func testSpecCountingExactly() {
        let scene = makeWaveScene(zombieCount: 3)

        let exactly3 = SceneStateSpec("exactly3Zombies") {
            Requires(exactly: 3, matching: .hasComponent(ZombieAIComponent.self))
        }
        let exactly2 = SceneStateSpec("exactly2Zombies") {
            Requires(exactly: 2, matching: .hasComponent(ZombieAIComponent.self))
        }

        XCTAssertTrue(exactly3.violations(against: scene.root).isEmpty)
        XCTAssertFalse(exactly2.violations(against: scene.root).isEmpty)
    }

    func testSpecAtMost() {
        let scene = makeWaveScene(zombieCount: 4)

        let spec = SceneStateSpec("atMost3") {
            Requires(atMost: 3, matching: .hasComponent(ZombieAIComponent.self))
        }

        XCTAssertFalse(spec.violations(against: scene.root).isEmpty)
    }

    func testCustomExpectation() {
        let scene = makeWaveScene()

        let spec = SceneStateSpec("playerHealthCheck") {
            Expect("player.lives == 3") { root in
                root.findEntity(named: "player")?.components[HealthComponent.self]?.lives == 3
            }
        }

        XCTAssertTrue(spec.violations(against: scene.root).isEmpty)
    }

    func testEntitySatisfiesWithMissingEntity() {
        let scene = TestScene { Entity("nothing") }

        let spec = SceneStateSpec("entityCheck") {
            Expect(entityNamed: "nonexistent", "something") { _ in true }
        }

        let violations = spec.violations(against: scene.root)
        XCTAssertFalse(violations.isEmpty, "missing entity should produce a violation")
    }

    func testEntityPredicateHasComponent() {
        let entity = Entity("zombie").component(ZombieAIComponent(state: .chasing))
        let pred = EntityPredicate.hasComponent(ZombieAIComponent.self)
        XCTAssertTrue(pred.matches(entity))
    }

    func testEntityPredicateNamed() {
        let entity = Entity("player")
        XCTAssertTrue(EntityPredicate.named("player").matches(entity))
        XCTAssertFalse(EntityPredicate.named("zombie").matches(entity))
    }
}

// MARK: - SceneInvariantTests

@MainActor
final class SceneInvariantTests: XCTestCase {

    func testNoNaNTransformsPassesOnCleanScene() {
        let scene = TestScene {
            Entity("a").position(0, 1, 0)
            Entity("b").position(1, 0, -2)
        }
        let violations = SceneInvariantSet {
            SceneInvariant.noNaNTransforms
        }.violations(in: scene.root)
        XCTAssertTrue(violations.isEmpty)
    }

    func testAlwaysPresentPassesWhenEntityExists() {
        let scene = TestScene { Entity("player") }
        let violations = SceneInvariantSet {
            SceneInvariant.alwaysPresent(named: "player")
        }.violations(in: scene.root)
        XCTAssertTrue(violations.isEmpty)
    }

    func testAlwaysPresentFailsWhenEntityMissing() {
        let scene = TestScene { Entity("other") }
        let violations = SceneInvariantSet {
            SceneInvariant.alwaysPresent(named: "player")
        }.violations(in: scene.root)
        XCTAssertFalse(violations.isEmpty)
    }

    func testNeverPresentFailsWhenEntityExists() {
        let scene = TestScene { Entity("mainMenuPanel") }
        let violations = SceneInvariantSet {
            SceneInvariant.neverPresent(named: "mainMenuPanel")
        }.violations(in: scene.root)
        XCTAssertFalse(violations.isEmpty)
    }

    func testCapInvariant() {
        let scene = TestScene {
            for i in 0..<6 {
                Entity("proj_\(i)").component(ProjectileComponent(velocity: .zero))
            }
        }
        let violations = SceneInvariantSet {
            SceneInvariant.cap(ProjectileComponent.self, atMost: 5)
        }.violations(in: scene.root)
        XCTAssertFalse(violations.isEmpty, "6 projectiles violates cap of 5")
    }

    func testMultipleInvariantsReportAllViolations() {
        let scene = TestScene {
            Entity("mainMenuPanel")
            // player missing, menu present
        }
        let violations = SceneInvariantSet {
            SceneInvariant.alwaysPresent(named: "player")
            SceneInvariant.neverPresent(named: "mainMenuPanel")
        }.violations(in: scene.root)
        XCTAssertEqual(violations.count, 2)
    }
}

// MARK: - SceneSnapshotTests

@MainActor
final class SceneSnapshotTests: XCTestCase {

    private func makeScene() -> TestScene {
        TestScene {
            Entity("head").children {
                Entity("gun")
                    .position(0.1, -0.1, -0.2)
                    .children { Entity("gunTip").position(0, 0, -0.15) }
            }
            Entity("zombie")
                .position(0, 0, -3)
                .collider(group: .init(rawValue: 1 << 8), mask: .init(rawValue: 1 << 1))
        }
    }

    func testSnapshotCapturesNames() {
        let scene = makeScene()
        let snap = SceneSnapshot(scene.root)
        XCTAssertEqual(snap.root.name, "root")
        XCTAssertTrue(snap.root.children.contains { $0.name == "head" })
        XCTAssertTrue(snap.root.children.contains { $0.name == "zombie" })
    }

    func testSnapshotCapturesCollisionGroups() {
        let scene = makeScene()
        let snap = SceneSnapshot(scene.root)
        let zombieNode = snap.root.children.first { $0.name == "zombie" }
        XCTAssertNotNil(zombieNode?.collisionGroup)
        XCTAssertEqual(zombieNode?.collisionGroup, 1 << 8)
    }

    func testTreeOutputContainsAllNames() {
        let scene = makeScene()
        let snap = SceneSnapshot(scene.root)
        let tree = snap.tree
        XCTAssertTrue(tree.contains("root"))
        XCTAssertTrue(tree.contains("head"))
        XCTAssertTrue(tree.contains("gun"))
        XCTAssertTrue(tree.contains("gunTip"))
        XCTAssertTrue(tree.contains("zombie"))
    }

    func testNamesOnlyOptionsOmitsPositionAndGroup() {
        let scene = makeScene()
        let snap = SceneSnapshot(scene.root, options: .namesOnly)
        let tree = snap.tree
        XCTAssertFalse(tree.contains("pos("), "names-only snapshot must not include positions")
        XCTAssertFalse(tree.contains("group:"), "names-only snapshot must not include collision groups")
    }

    func testEntityCountIsCorrect() {
        let scene = makeScene()
        let snap = SceneSnapshot(scene.root)
        // root + head + gun + gunTip + zombie = 5
        XCTAssertEqual(snap.entityCount, 5)
    }

    func testMatchingSnapshotsProduceNoDiff() {
        let scene = makeScene()
        let snap1 = SceneSnapshot(scene.root)
        let snap2 = SceneSnapshot(scene.root)
        XCTAssertNil(snap1.diff(from: snap2))
    }

    func testDiffDetectsAddedNode() {
        let scene = makeScene()
        let before = SceneSnapshot(scene.root)

        scene.root.addChild(Entity("newEnemy"))

        let after = SceneSnapshot(scene.root)
        let diff = after.diff(from: before)
        XCTAssertNotNil(diff, "diff should detect added entity")
        XCTAssertTrue(diff?.contains("newEnemy") ?? false)
    }

    func testDiffDetectsRemovedNode() {
        let scene = makeScene()
        let before = SceneSnapshot(scene.root)

        scene["zombie"]?.removeFromParent()

        let after = SceneSnapshot(scene.root)
        let diff = after.diff(from: before)
        XCTAssertNotNil(diff, "diff should detect removed entity")
        XCTAssertTrue(diff?.contains("zombie") ?? false)
    }

    func testDiffDetectsMovedNode() {
        let scene = makeScene()
        let before = SceneSnapshot(scene.root)

        scene["zombie"]?.position = SIMD3<Float>(10, 0, -3)  // moved far away

        let after = SceneSnapshot(scene.root)
        let diff = after.diff(from: before)
        XCTAssertNotNil(diff, "diff should detect position change")
    }

    func testMaxDepthLimitsCapture() {
        let scene = makeScene()
        let snap = SceneSnapshot(scene.root, options: SnapshotOptions(maxDepth: 1))
        // depth 0 = root, depth 1 = head + zombie. gunTip (depth 3) should be absent.
        let tree = snap.tree
        XCTAssertFalse(tree.contains("gunTip"), "maxDepth=1 should not capture gunTip at depth 3")
    }
}

// MARK: - EntityAssertionTests (new helpers)

@MainActor
final class EntityAssertionTests: XCTestCase {

    func testAssertEntityName() {
        let entity = Entity("gun")
        XCTAssertEntityName(entity, "gun")
    }

    func testAssertChildCount() {
        let parent = Entity("parent")
        parent.addChild(Entity("a"))
        parent.addChild(Entity("b"))
        XCTAssertChildCount(parent, 2)
    }

    func testAssertHasChildren() {
        let parent = Entity("parent")
        parent.addChild(Entity("child"))
        XCTAssertHasChildren(parent)
    }

    func testAssertNoChildren() {
        let leaf = Entity("leaf")
        XCTAssertNoChildren(leaf)
    }

    func testAssertEnabled() {
        let entity = Entity("e")
        entity.isEnabled = true
        XCTAssertEnabled(entity)
    }

    func testAssertDisabled() {
        let entity = Entity("e")
        entity.isEnabled = false
        XCTAssertDisabled(entity)
    }

    func testAssertSubtreeSize() {
        let root = Entity("root")
        root.addChild(Entity("child"))
        root.addChild(Entity("child2"))
        XCTAssertSubtreeSize(root, equals: 3)  // root + 2 children
    }

    func testAssertUniformScale() {
        let entity = Entity("e")
        entity.scale = SIMD3<Float>(repeating: 0.5)
        XCTAssertUniformScale(entity, equals: 0.5, accuracy: 0.001)
    }

    func testAssertColliderMask() {
        let zombie = CollisionGroup(rawValue: 1 << 8)
        let projectile = CollisionGroup(rawValue: 1 << 1)
        let entity = Entity("hitbox").collider(group: zombie, mask: projectile)
        XCTAssertColliderMask(entity, contains: projectile)
    }

    func testAssertNoCollider() {
        let entity = Entity("floating")
        XCTAssertNoCollider(entity)
    }

    func testAssertRoot() {
        let root = Entity("root")
        XCTAssertRoot(root)
    }

    func testAssertHasParent() {
        let parent = Entity("parent")
        let child  = Entity("child")
        parent.addChild(child)
        XCTAssertHasParent(child)
    }
}
