import XCTest
import RealityKit
import simd
@testable import ImmersiveTesting

// MARK: - SpatialLayoutSpec tests

@MainActor
final class SpatialLayoutSpecTests: XCTestCase {

    // Scene: avatar at origin facing −Z, npc 3m in front, gun in right hand, hud at eye level.
    private func makeScene() -> TestScene {
        TestScene {
            Entity("avatar").position(0, 1.6, 0)
            Entity("npc").position(0.2, 0, -3.0)       // in front, 3 m out
            Entity("gun").position(0.15, 1.2, -0.4)    // right hand, forward, mid height
            Entity("hud").position(0, 1.65, -1.0)      // eye level, ahead
            Entity("pickup").position(0, 0.05, -1.0)   // near floor, 1 m ahead
            Entity("holster").position(0.2, 1.0, 0.3)  // behind, hip height
        }
    }

    // MARK: withinReach

    func testWithinReachPasses() {
        let scene = makeScene()
        let spec = SpatialLayoutSpec("gun reach", relativeTo: scene["avatar"]!) {
            .withinReach(named: "gun", within: 2.0)
        }
        XCTAssertTrue(spec.violations(against: scene.root).isEmpty)
    }

    func testWithinReachFailsWhenTooFar() {
        let scene = makeScene()
        let spec = SpatialLayoutSpec("npc reach", relativeTo: scene["avatar"]!) {
            .withinReach(named: "npc", within: 0.5)   // npc is 3 m away
        }
        XCTAssertFalse(spec.violations(against: scene.root).isEmpty)
    }

    // MARK: atHeight

    func testAtHeightPasses() {
        let scene = makeScene()
        let spec = SpatialLayoutSpec("gun height", relativeTo: scene["avatar"]!) {
            .atHeight(named: "gun", min: 0.9, max: 1.6)
        }
        XCTAssertTrue(spec.violations(against: scene.root).isEmpty)
    }

    func testAtHeightFailsWhenBelowFloor() {
        let scene = makeScene()
        let spec = SpatialLayoutSpec("gun height", relativeTo: scene["avatar"]!) {
            .atHeight(named: "gun", min: 1.8, max: 2.5)   // gun is at 1.2, not 1.8+
        }
        XCTAssertFalse(spec.violations(against: scene.root).isEmpty)
    }

    func testPickupNearFloor() {
        let scene = makeScene()
        let spec = SpatialLayoutSpec("pickup floor level", relativeTo: scene["avatar"]!) {
            .atHeight(named: "pickup", min: -0.1, max: 0.3)
        }
        XCTAssertTrue(spec.violations(against: scene.root).isEmpty)
    }

    // MARK: inFrontOf

    func testInFrontOfPasses() {
        // Avatar at origin, worldForward = −Z. npc at z=−3 is in front.
        let scene = makeScene()
        let spec = SpatialLayoutSpec("npc ahead", relativeTo: scene["avatar"]!) {
            .inFrontOf(named: "npc", within: 5.0)
        }
        XCTAssertTrue(spec.violations(against: scene.root).isEmpty)
    }

    func testInFrontOfFailsForEntityBehind() {
        let scene = makeScene()
        // holster is at z=+0.3 (behind a default-orientation entity facing −Z)
        let spec = SpatialLayoutSpec("holster check", relativeTo: scene["avatar"]!) {
            .inFrontOf(named: "holster", within: 5.0)
        }
        XCTAssertFalse(spec.violations(against: scene.root).isEmpty)
    }

    func testInFrontOfNoDistanceLimit() {
        let scene = makeScene()
        let spec = SpatialLayoutSpec("npc direction", relativeTo: scene["avatar"]!) {
            .inFrontOf(named: "npc", within: nil)
        }
        XCTAssertTrue(spec.violations(against: scene.root).isEmpty)
    }

    // MARK: behind

    func testBehindPasses() {
        let scene = makeScene()
        let spec = SpatialLayoutSpec("holster behind", relativeTo: scene["avatar"]!) {
            .behind(named: "holster", within: nil)
        }
        XCTAssertTrue(spec.violations(against: scene.root).isEmpty)
    }

    func testBehindFailsForEntityInFront() {
        let scene = makeScene()
        let spec = SpatialLayoutSpec("npc behind?", relativeTo: scene["avatar"]!) {
            .behind(named: "npc", within: nil)
        }
        XCTAssertFalse(spec.violations(against: scene.root).isEmpty)
    }

    // MARK: above

    func testAbovePasses() {
        let scene = TestScene {
            Entity("head").position(0, 1.7, -3)
            Entity("torso").position(0, 1.1, -3)
        }
        let ref = Entity("ref")
        let spec = SpatialLayoutSpec("anatomy", relativeTo: ref) {
            .above("head", "torso")
        }
        XCTAssertTrue(spec.violations(against: scene.root).isEmpty)
    }

    func testAboveFailsWhenInverted() {
        let scene = TestScene {
            Entity("head").position(0, 0.5, 0)   // below torso — wrong
            Entity("torso").position(0, 1.2, 0)
        }
        let ref = Entity("ref")
        let spec = SpatialLayoutSpec("anatomy inverted", relativeTo: ref) {
            .above("head", "torso")
        }
        XCTAssertFalse(spec.violations(against: scene.root).isEmpty)
    }

    // MARK: atEyeLevel

    func testAtEyeLevelPasses() {
        let scene = makeScene()
        let spec = SpatialLayoutSpec("hud eye level", relativeTo: scene["avatar"]!) {
            .atEyeLevel(named: "hud", eyeHeight: 1.6, tolerance: 0.15)
        }
        XCTAssertTrue(spec.violations(against: scene.root).isEmpty)
    }

    func testAtEyeLevelFailsWhenTooLow() {
        let scene = makeScene()
        let spec = SpatialLayoutSpec("pickup eye level", relativeTo: scene["avatar"]!) {
            .atEyeLevel(named: "pickup", eyeHeight: 1.6, tolerance: 0.15)  // pickup is at 0.05
        }
        XCTAssertFalse(spec.violations(against: scene.root).isEmpty)
    }

    // MARK: noCloserThan

    func testNoCloserThanPasses() {
        let scene = makeScene()
        let spec = SpatialLayoutSpec("npc spawn ring", relativeTo: scene["avatar"]!) {
            .noCloserThan(named: "npc", minimum: 1.5)
        }
        XCTAssertTrue(spec.violations(against: scene.root).isEmpty)
    }

    func testNoCloserThanFailsWhenTooClose() {
        let scene = TestScene {
            Entity("avatar").position(0, 1.6, 0)
            Entity("npc").position(0, 1.6, -0.3)   // 0.3 m away — inside personal space
        }
        let spec = SpatialLayoutSpec("npc spawn ring", relativeTo: scene["avatar"]!) {
            .noCloserThan(named: "npc", minimum: 1.5)
        }
        XCTAssertFalse(spec.violations(against: scene.root).isEmpty)
    }

    // MARK: sameElevationAs

    func testSameElevationAsPasses() {
        let scene = makeScene()
        // hud is 0.05 m above avatar (1.65 vs 1.6)
        let spec = SpatialLayoutSpec("hud elevation", relativeTo: scene["avatar"]!) {
            .sameElevationAs(named: "hud", tolerance: 0.1)
        }
        XCTAssertTrue(spec.violations(against: scene.root).isEmpty)
    }

    // MARK: missing entity

    func testMissingEntityProducesViolation() {
        let scene = makeScene()
        let spec = SpatialLayoutSpec("missing", relativeTo: scene["avatar"]!) {
            .withinReach(named: "nonexistent", within: 5.0)
        }
        XCTAssertFalse(spec.violations(against: scene.root).isEmpty)
    }

    // MARK: combined multi-expectation spec

    func testFullWeaponInHandSpec() {
        let scene = makeScene()
        let spec = SpatialLayoutSpec("weapon-in-hand", relativeTo: scene["avatar"]!) {
            SpatialExpectation.inFrontOf(named: "gun", within: 1.0)
            SpatialExpectation.atHeight(named: "gun", min: 0.9, max: 1.8)
            SpatialExpectation.withinReach(named: "gun", within: 0.8)
        }
        XCTAssertTrue(spec.violations(against: scene.root).isEmpty, spec.violations(against: scene.root).description)
    }

    func testFullRoundActiveLayoutSpec() {
        let scene = makeScene()
        // Use explicit enum prefix when combining 5+ expectations — Swift's type inference
        // for implicit member syntax (.xxx) degrades with many result-builder expressions.
        let spec = SpatialLayoutSpec("round-active", relativeTo: scene["avatar"]!) {
            SpatialExpectation.atEyeLevel(named: "hud", eyeHeight: 1.6, tolerance: 0.3)
            SpatialExpectation.inFrontOf(named: "npc", within: 5.0)
            SpatialExpectation.noCloserThan(named: "npc", minimum: 1.0)
            SpatialExpectation.atHeight(named: "pickup", min: -0.1, max: 0.4)
            SpatialExpectation.behind(named: "holster", within: nil)
        }
        XCTAssertTrue(spec.violations(against: scene.root).isEmpty, spec.violations(against: scene.root).description)
    }
}

// MARK: - ASCII spatial map tests

@MainActor
final class SpatialMapTests: XCTestCase {

    // Scene: avatar at centre, npc 2m in front (−Z), gun to the right.
    private func makeScene() -> TestScene {
        TestScene {
            Entity("avatar").position(0, 1.6, 0)
            Entity("npc").position(0, 1.0, -2)      // in front
            Entity("gun").position(1.5, 1.2, 0)     // to the right
        }
    }

    // MARK: topDownMap

    func testTopDownMapProducesCorrectRowCount() {
        let scene = makeScene()
        let snap = SceneSnapshot(scene.root)
        let map = snap.topDownMap(relativeTo: scene["avatar"]!, range: 4.0, resolution: 9) { s in
            s["avatar"] = "@"; s["npc"] = "N"; s["gun"] = "G"
        }
        XCTAssertEqual(map.lines.count, 9)
    }

    func testTopDownMapCentreSymbol() {
        let scene = makeScene()
        let snap = SceneSnapshot(scene.root)
        let map = snap.topDownMap(relativeTo: scene["avatar"]!, range: 4.0, resolution: 9) { s in
            s["avatar"] = "@"
        }
        // Avatar is the reference — it should land at or near the centre cell (4,4).
        let centreRow = map.lines[4]
        XCTAssertTrue(centreRow.contains("@"), "Avatar symbol '@' must appear in centre row.\nMap:\n\(map.text)")
    }

    func testTopDownMapNPCAppearsAboveCentre() {
        // NPC is at z=−2 (in front of avatar). In the top-down map z-axis points downward
        // on screen, so −Z → lower row index → NPC appears ABOVE the centre row.
        let scene = makeScene()
        let snap = SceneSnapshot(scene.root)
        let map = snap.topDownMap(relativeTo: scene["avatar"]!, range: 4.0, resolution: 9) { s in
            s["avatar"] = "@"; s["npc"] = "N"
        }
        let npcRow = map.lines.firstIndex(where: { $0.contains("N") })
        let avatarRow = map.lines.firstIndex(where: { $0.contains("@") })
        XCTAssertNotNil(npcRow, "NPC 'N' must appear in the map.\nMap:\n\(map.text)")
        XCTAssertNotNil(avatarRow, "Avatar '@' must appear in the map.\nMap:\n\(map.text)")
        if let nr = npcRow, let ar = avatarRow {
            XCTAssertLessThan(nr, ar, "NPC (in front, −Z) should be above avatar in the top-down map.\nMap:\n\(map.text)")
        }
    }

    func testTopDownMapGunAppearsToRightOfAvatar() {
        // Gun is at x=+1.5 (right of avatar). In the top-down map +X → higher column index.
        let scene = makeScene()
        let snap = SceneSnapshot(scene.root)
        let map = snap.topDownMap(relativeTo: scene["avatar"]!, range: 4.0, resolution: 9) { s in
            s["avatar"] = "@"; s["gun"] = "G"
        }
        func colOf(_ sym: Character) -> Int? {
            for line in map.lines {
                let cells = line.split(separator: " ")
                if let idx = cells.firstIndex(where: { $0 == String(sym) }) { return idx }
            }
            return nil
        }
        let avatarCol = colOf("@")
        let gunCol    = colOf("G")
        XCTAssertNotNil(gunCol, "Gun 'G' must appear in the map.\nMap:\n\(map.text)")
        if let ac = avatarCol, let gc = gunCol {
            XCTAssertGreaterThan(gc, ac, "Gun (+X) should appear to the right of avatar.\nMap:\n\(map.text)")
        }
    }

    func testTopDownMapClipsOutOfBoundsEntity() {
        let scene = TestScene {
            Entity("avatar").position(0, 1.6, 0)
            Entity("distant").position(0, 0, -100)   // way outside range
        }
        let snap = SceneSnapshot(scene.root)
        let map = snap.topDownMap(relativeTo: scene["avatar"]!, range: 4.0, resolution: 9) { s in
            s["avatar"] = "@"; s["distant"] = "D"
        }
        XCTAssertTrue(map.clipped.contains("distant"), "Entity outside range must be in clipped list")
        XCTAssertFalse(map.text.contains("D"), "Clipped entity must not appear in the map")
    }

    func testTopDownMapTextLineCountMatchesResolution() {
        let scene = makeScene()
        let snap = SceneSnapshot(scene.root)
        for res in [5, 9, 11, 15] {
            let map = snap.topDownMap(relativeTo: scene["avatar"]!, range: 3.0, resolution: res) { _ in }
            XCTAssertEqual(map.lines.count, res, "resolution \(res) must produce \(res) lines")
        }
    }

    // MARK: sideMap

    func testSideMapProducesCorrectRowCount() {
        let scene = makeScene()
        let snap = SceneSnapshot(scene.root)
        let map = snap.sideMap(relativeTo: scene["avatar"]!, range: 3.0, resolution: 7) { s in
            s["avatar"] = "@"
        }
        XCTAssertEqual(map.lines.count, 7)
    }

    func testSideMapEyeLevelHUDAppearsAboveFloorPickup() {
        let scene = TestScene {
            Entity("avatar").position(0, 1.6, 0)
            Entity("hud").position(0, 1.65, -1.0)    // near eye level
            Entity("pickup").position(0, 0.1, -1.0)  // floor level
        }
        let snap = SceneSnapshot(scene.root)
        let map = snap.sideMap(relativeTo: scene["avatar"]!, range: 3.0, resolution: 9) { s in
            s["avatar"] = "@"; s["hud"] = "H"; s["pickup"] = "P"
        }
        let hudRow    = map.lines.firstIndex(where: { $0.contains("H") })
        let pickupRow = map.lines.firstIndex(where: { $0.contains("P") })
        XCTAssertNotNil(hudRow,    "HUD 'H' must appear in the side map.\nMap:\n\(map.text)")
        XCTAssertNotNil(pickupRow, "Pickup 'P' must appear in the side map.\nMap:\n\(map.text)")
        // Lower row index = higher on screen = higher Y in world
        if let hr = hudRow, let pr = pickupRow {
            XCTAssertLessThan(hr, pr, "HUD (higher Y) should appear above pickup in side map.\nMap:\n\(map.text)")
        }
    }

    // MARK: XCTAssertTopDownMap wildcard matching

    func testTopDownMapWildcardAssertionPasses() {
        let scene = makeScene()
        let snap = SceneSnapshot(scene.root)

        // Build the actual map to derive the expected string dynamically — this tests
        // the wildcard matching logic rather than hardcoding pixel-exact positions.
        let map = snap.topDownMap(relativeTo: scene["avatar"]!, range: 4.0, resolution: 5) { s in
            s["avatar"] = "@"; s["npc"] = "N"
        }
        // Replace every non-dot, non-@ cell with "_" wildcard to make a lenient expected string.
        let wildcardExpected = map.lines.map { line in
            line.split(separator: " ").map { cell -> String in
                cell == "@" || cell == "N" ? String(cell) : "_"
            }.joined(separator: " ")
        }.joined(separator: "\n")

        // Should pass because wildcards match anything.
        XCTAssertTopDownMap(snap, relativeTo: scene["avatar"]!, range: 4.0, resolution: 5, symbols: { s in
            s["avatar"] = "@"; s["npc"] = "N"
        }, matches: wildcardExpected)
    }
}
