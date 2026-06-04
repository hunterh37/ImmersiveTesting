import XCTest
import RealityKit
import simd
@testable import ImmersiveTesting

@MainActor
final class Tier1Tests: XCTestCase {

    func makeScene() -> TestScene {
        TestScene {
            Entity("head").children {
                Entity("pointer")
                    .position(0.1, -0.1, -0.2)
                    .children { Entity("pointerTip").position(0, 0, -0.15) }
            }
            Entity("npc")
                .position(0, 0, -3)
                .component(NPCAIComponent(state: .pursuing))
                .collider(group: .init(rawValue: 1 << 13), mask: .init(rawValue: 1 << 17))
            Entity("avatar")
                .position(0, 1.6, 0)
                .component(VitalComponent(lives: 3))
        }
    }

    func testLookupByDottedPath() {
        let scene = makeScene()
        XCTAssertNotNil(scene["pointer.pointerTip"])
        XCTAssertEqual(scene["pointer.pointerTip"]?.name, "pointerTip")
    }

    func testLookupHandlesLiteralDotInName() {
        // An entity whose own name contains a "." must be found by exact match,
        // not mis-parsed as a path. (Regression: dotted-path split swallowed these.)
        let scene = TestScene {
            Entity("npc_0").children {
                Entity("npc_0.head").position(0, 1.7, 0)
            }
        }
        // Exact full-name match wins.
        XCTAssertEqual(scene["npc_0.head"]?.name, "npc_0.head")
        // Strict path walk still resolves child segments.
        XCTAssertNil(scene.entity(atPath: "npc_0.head"),
                     "no child literally named 'head' exists under npc_0")
    }

    func testSpatialAssertions() {
        let scene = makeScene()
        XCTAssertPosition(scene["avatar"]!, near: [0, 1.6, 0], within: 0.001)
        XCTAssertDistance(scene["avatar"]!, to: scene["npc"]!, lessThan: 4)
        XCTAssertFiniteTransforms(scene.root)
    }

    func testComponentAssertions() {
        let scene = makeScene()
        XCTAssertHasComponent(scene["npc"]!, NPCAIComponent.self)
        XCTAssertComponent(scene["npc"]!, NPCAIComponent.self) { $0.state == .pursuing }
        XCTAssertComponentCount(scene.root, VitalComponent.self, equals: 1)
        XCTAssertNoComponent(scene["pointer"]!, VitalComponent.self)
    }

    func testHierarchyAssertions() {
        let scene = makeScene()
        XCTAssertDescendant(scene["pointer.pointerTip"]!, of: scene["head"]!)
        XCTAssertChild(scene["pointer"]!, of: scene["head"]!)
        XCTAssertEntityExists(scene.root, named: "npc")
        XCTAssertNoEntity(scene.root, named: "mainMenuPanel")
    }

    func testCollisionGroups() {
        let scene = makeScene()
        XCTAssertColliderGroup(scene["npc"]!, contains: .init(rawValue: 1 << 13))
    }
}
