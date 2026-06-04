import RealityKit

// Shared component stubs used across Tier1Tests and Tier2Tests.
// Declared `internal` (module-level) so both files can use them without redeclaration.

struct VitalComponent: Component { var lives: Int }

struct NPCAIComponent: Component {
    enum State { case idle, pursuing, inactive }
    var state: State
    var health: Float = 100
}

struct ProjectileComponent: Component {
    var velocity: SIMD3<Float>
    var hitRegistered: Bool = false
}

struct PickupComponent: Component { var quantity: Int }

struct RoundComponent: Component { var index: Int; var activeCount: Int }
