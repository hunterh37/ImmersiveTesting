import SwiftUI
import RealityKit

struct ContentView: View {
    var body: some View {
        RealityView { content in
            content.add(SceneBuilder.makeDemo())
        }
        .ignoresSafeArea()
    }
}

// Shared scene used by both the live app and the render tests.
enum SceneBuilder {
    @MainActor
    static func makeDemo() -> Entity {
        let root = Entity()

        // Red sphere
        let sphere = ModelEntity(
            mesh: .generateSphere(radius: 0.1),
            materials: [SimpleMaterial(color: .systemRed, isMetallic: true)]
        )
        sphere.position = [0, 0, -0.5]
        root.addChild(sphere)

        // Blue box
        let box = ModelEntity(
            mesh: .generateBox(size: 0.12),
            materials: [SimpleMaterial(color: .systemBlue, isMetallic: false)]
        )
        box.position = [0.25, 0, -0.5]
        root.addChild(box)

        // Green cylinder
        let cylinder = ModelEntity(
            mesh: .generateBox(width: 0.08, height: 0.2, depth: 0.08),
            materials: [SimpleMaterial(color: .systemGreen, isMetallic: false)]
        )
        cylinder.position = [-0.25, 0, -0.5]
        root.addChild(cylinder)

        // Floor plane
        let floor = ModelEntity(
            mesh: .generatePlane(width: 1.0, depth: 1.0),
            materials: [SimpleMaterial(color: .systemGray, isMetallic: false)]
        )
        floor.position = [0, -0.15, -0.5]
        root.addChild(floor)

        return root
    }

    @MainActor
    static func makeColoredSpheres() -> Entity {
        let root = Entity()
        let colors: [UIColor] = [.systemRed, .systemOrange, .systemYellow, .systemGreen, .systemBlue, .systemPurple]
        for (i, color) in colors.enumerated() {
            let sphere = ModelEntity(
                mesh: .generateSphere(radius: 0.06),
                materials: [SimpleMaterial(color: color, isMetallic: true)]
            )
            let angle = Float(i) / Float(colors.count) * 2 * .pi
            sphere.position = [cos(angle) * 0.3, 0, sin(angle) * 0.3 - 0.5]
            root.addChild(sphere)
        }
        return root
    }
}
