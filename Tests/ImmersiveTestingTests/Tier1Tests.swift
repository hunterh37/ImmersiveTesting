import XCTest
import RealityKit
import simd
@testable import ImmersiveTesting

@MainActor
final class Tier1Tests: XCTestCase {

    func makeScene() -> TestScene {
        TestScene {
            Entity("head").children {
                Entity("gun")
                    .position(0.1, -0.1, -0.2)
                    .children { Entity("gunTip").position(0, 0, -0.15) }
            }
            Entity("zombie")
                .position(0, 0, -3)
                .component(ZombieAIComponent(state: .chasing))
                .collider(group: .init(rawValue: 1 << 13), mask: .init(rawValue: 1 << 17))
            Entity("player")
                .position(0, 1.6, 0)
                .component(HealthComponent(lives: 3))
        }
    }

    func testLookupByDottedPath() {
        let scene = makeScene()
        XCTAssertNotNil(scene["gun.gunTip"])
        XCTAssertEqual(scene["gun.gunTip"]?.name, "gunTip")
    }

    func testLookupHandlesLiteralDotInName() {
        // An entity whose own name contains a "." must be found by exact match,
        // not mis-parsed as a path. (Regression: dotted-path split swallowed these.)
        let scene = TestScene {
            Entity("zombie_0").children {
                Entity("zombie_0.head").position(0, 1.7, 0)
            }
        }
        // Exact full-name match wins.
        XCTAssertEqual(scene["zombie_0.head"]?.name, "zombie_0.head")
        // Strict path walk still resolves child segments.
        XCTAssertNil(scene.entity(atPath: "zombie_0.head"),
                     "no child literally named 'head' exists under zombie_0")
    }

    func testSpatialAssertions() {
        let scene = makeScene()
        XCTAssertPosition(scene["player"]!, near: [0, 1.6, 0], within: 0.001)
        XCTAssertDistance(scene["player"]!, to: scene["zombie"]!, lessThan: 4)
        XCTAssertFiniteTransforms(scene.root)
    }

    func testComponentAssertions() {
        let scene = makeScene()
        XCTAssertHasComponent(scene["zombie"]!, ZombieAIComponent.self)
        XCTAssertComponent(scene["zombie"]!, ZombieAIComponent.self) { $0.state == .chasing }
        XCTAssertComponentCount(scene.root, HealthComponent.self, equals: 1)
        XCTAssertNoComponent(scene["gun"]!, HealthComponent.self)
    }

    func testHierarchyAssertions() {
        let scene = makeScene()
        XCTAssertDescendant(scene["gun.gunTip"]!, of: scene["head"]!)
        XCTAssertChild(scene["gun"]!, of: scene["head"]!)
        XCTAssertEntityExists(scene.root, named: "zombie")
        XCTAssertNoEntity(scene.root, named: "mainMenuPanel")
    }

    func testCollisionGroups() {
        let scene = makeScene()
        XCTAssertColliderGroup(scene["zombie"]!, contains: .init(rawValue: 1 << 13))
    }
}
