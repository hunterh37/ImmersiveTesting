import XCTest
import RealityKit
import simd
@testable import ImmersiveTesting

// MARK: - Provider fake tests

@MainActor
final class ProviderFakeTests: XCTestCase {

    func testFakeWorldTrackingReturnsScriptedPose() {
        let world = FakeWorldTracking()
        world.position = [5, 1.6, 0]
        XCTAssertEqual(world.deviceTransform().translation, [5, 1.6, 0])
        XCTAssertEqual(world.devicePosition(), [5, 1.6, 0])
    }

    func testSpySceneEffectsRecordsCallsInOrder() {
        let fx = SpySceneEffects()
        fx.startEffect(named: "glitchA")
        fx.startEffect(named: "glitchB")
        XCTAssertEqual(fx.startedEffects, ["glitchA", "glitchB"])
        fx.reset()
        XCTAssertTrue(fx.startedEffects.isEmpty)
    }

    func testScriptedHandsPinchThreshold() {
        let hands = ScriptedHands()
        XCTAssertFalse(hands.isRightPinching())       // open by default
        hands.rightPinchDistance = 0.05
        XCTAssertTrue(hands.isRightPinching())          // below 0.09
        XCTAssertTrue(hands.isRightPinching(threshold: 0.09))
        XCTAssertFalse(hands.isLeftPinching())
    }

    func testSeededRandomIsDeterministic() {
        let a = SeededRandom(seed: 42)
        let b = SeededRandom(seed: 42)
        for _ in 0..<100 {
            XCTAssertEqual(a.next(), b.next(), accuracy: 0)
        }
    }

    func testSeededRandomStaysInUnitInterval() {
        let rng = SeededRandom(seed: 1)
        for _ in 0..<10_000 {
            let v = rng.next()
            XCTAssertGreaterThanOrEqual(v, 0)
            XCTAssertLessThan(v, 1)
        }
    }

    func testSeededRandomDiffersBySeed() {
        let a = SeededRandom(seed: 1)
        let b = SeededRandom(seed: 2)
        // Extremely unlikely to match across 10 draws if seeds differ.
        var anyDifferent = false
        for _ in 0..<10 where a.next() != b.next() { anyDifferent = true }
        XCTAssertTrue(anyDifferent)
    }

    func testRandomRangeAndUnitVector() {
        let rng = SeededRandom(seed: 7)
        for _ in 0..<1000 {
            let v = rng.next(in: 2...4)
            XCTAssertGreaterThanOrEqual(v, 2)
            XCTAssertLessThanOrEqual(v, 4)
        }
        let dir = SeededRandom(seed: 7).unitVectorXZ()
        XCTAssertEqual(length(dir), 1, accuracy: 1e-5)
        XCTAssertEqual(dir.y, 0)
    }
}

// MARK: - SceneEnvironment tests

@MainActor
final class SceneEnvironmentTests: XCTestCase {

    func testDefaultEnvironmentIsAllFakes() {
        let env = CompositeSceneEnvironment()
        XCTAssertTrue(env.worldTracking is FakeWorldTracking)
        XCTAssertTrue(env.sceneEffects is SpySceneEffects)
        XCTAssertTrue(env.hands is ScriptedHands)
        XCTAssertTrue(env.random is SeededRandom)
    }

    func testIndividualProviderOverride() {
        let world = FakeWorldTracking()
        world.position = [1, 2, 3]
        let env = CompositeSceneEnvironment(worldTracking: world)
        XCTAssertEqual(env.worldTracking.devicePosition(), [1, 2, 3])
    }

    func testFakeFactory() {
        let hands = ScriptedHands(rightPinchDistance: 0.04)
        let env: any SceneEnvironment = .fake(hands: hands)
        XCTAssertTrue(env.hands.isRightPinching())
    }
}

// MARK: - SceneBuilder + harness env integration

/// Stand-in components for the integration scene (module-internal, distinct from Tier1/2).
private struct ChaserTag: Component { var speed: Float }

/// A minimal real-style builder: rings `Chaser` entities around the device position read
/// from the injected environment, with a seeded jitter radius.
private struct RingSceneBuilder: SceneBuilder {
    struct Config { var count: Int; var radius: Float }

    func build(_ config: Config, env: any SceneEnvironment) -> Entity {
        let root = Entity("ringRoot")
        let center = env.worldTracking.devicePosition()
        for i in 0..<config.count {
            let dir = env.random.unitVectorXZ()
            let jitter = env.random.next(in: 0.9...1.1)
            let pos = center + dir * config.radius * jitter
            root.addChild(
                Entity("chaser_\(i)")
                    .position(pos)
                    .component(ChaserTag(speed: 1.0))
            )
        }
        return root
    }
}

@MainActor
final class SceneBuilderTests: XCTestCase {

    func testBuilderReadsInjectedDevicePosition() {
        let world = FakeWorldTracking()
        world.position = [10, 0, 0]
        let env = CompositeSceneEnvironment(worldTracking: world, random: SeededRandom(seed: 1))

        let scene = RingSceneBuilder().makeScene(.init(count: 4, radius: 2), env: env)

        let chasers = scene.root.entities(with: ChaserTag.self)
        XCTAssertEqual(chasers.count, 4)
        // Every chaser sits within [radius*0.9, radius*1.1] of the scripted center.
        for c in chasers {
            let d = distance(c.worldPosition, [10, 0, 0])
            XCTAssertGreaterThanOrEqual(d, 2 * 0.9 - 1e-4)
            XCTAssertLessThanOrEqual(d, 2 * 1.1 + 1e-4)
        }
    }

    func testSeededBuildIsReproducible() {
        func build() -> SceneSnapshot {
            let env = CompositeSceneEnvironment(random: SeededRandom(seed: 99))
            let scene = RingSceneBuilder().makeScene(.init(count: 5, radius: 3), env: env)
            return SceneSnapshot(scene.root)
        }
        XCTAssertNil(build().diff(from: build()), "same seed must produce an identical graph")
    }

    func testAdoptingInitWrapsRealRoot() {
        let root = Entity("realRoot")
        root.addChild(Entity("child"))
        let scene = TestScene(adopting: root)
        XCTAssertEqual(scene.root.name, "realRoot")
        XCTAssertNotNil(scene["child"])
    }
}

// MARK: - Environment-aware harness step

@MainActor
final class HarnessEnvironmentTests: XCTestCase {

    func testStepReadsScriptedDevicePoseEachFrame() {
        let world = FakeWorldTracking()
        world.position = [10, 0, 0]
        let env = CompositeSceneEnvironment(worldTracking: world)

        let scene = TestScene {
            Entity("zombie").position(0, 0, 0).component(ChaserTag(speed: 2))
        }
        let harness = SystemHarness(scene: scene, environment: env)

        // Chase the live device position pulled from the environment every tick.
        harness.registerStep("chase") { entities, dt, env in
            let target = env.worldTracking.devicePosition()
            for e in entities {
                guard let tag = e.components[ChaserTag.self] else { continue }
                let toTarget = target - e.position
                if length(toTarget) > 1e-4 {
                    e.position += normalize(toTarget) * tag.speed * dt
                }
            }
        }

        let zombie = scene["zombie"]!
        harness.tick(frames: 45)
        let after = zombie.position.x
        XCTAssertGreaterThan(after, 0, "zombie should have moved toward +x device pose")

        // Teleport the device; the same step must now steer the zombie further along.
        world.position = [20, 0, 0]
        harness.tick(frames: 45)
        XCTAssertGreaterThan(zombie.position.x, after, "zombie keeps chasing the moved pose")
    }

    func testDefaultHarnessEnvironmentExists() {
        let scene = TestScene { Entity("a") }
        let harness = SystemHarness(scene: scene)
        XCTAssertTrue(harness.environment is CompositeSceneEnvironment)
    }

    func testBackCompatTwoArgStepStillWorks() {
        // Guards the existing (entities, dt) overload against the new env overload.
        let scene = TestScene {
            Entity("p").position(0, 0, 0).component(ChaserTag(speed: 1))
        }
        let harness = SystemHarness(scene: scene)
        harness.registerStep("move") { entities, dt in
            for e in entities where e.components[ChaserTag.self] != nil {
                e.position.z -= dt
            }
        }
        harness.tick(frames: 90)
        XCTAssertEqual(scene["p"]!.position.z, -1, accuracy: 0.05)
    }
}
