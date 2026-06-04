import RealityKit

// Shared component stubs used across Tier1Tests and Tier2Tests.
// Declared `internal` (module-level) so both files can use them without redeclaration.

struct HealthComponent: Component { var lives: Int }

struct ZombieAIComponent: Component {
    enum State { case idle, chasing, dead }
    var state: State
    var health: Float = 100
}

struct ProjectileComponent: Component {
    var velocity: SIMD3<Float>
    var hitRegistered: Bool = false
}

struct AmmoPickupComponent: Component { var rounds: Int }

struct WaveComponent: Component { var index: Int; var aliveCount: Int }
