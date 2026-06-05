// Scene.swift — Edit this file to define what to render.
// Then run: swift run ImmersiveCaptureApp
// The PNG path is printed to stdout when done.

import SwiftUI
import RealityKit

@MainActor
func makeScene() -> some View {
    RealityView { content in
        // Red sphere
        let sphere = ModelEntity(
            mesh: .generateSphere(radius: 0.1),
            materials: [SimpleMaterial(color: .red, isMetallic: true)]
        )
        sphere.position = [0, 0, -0.5]
        content.add(sphere)

        // Blue box
        let box = ModelEntity(
            mesh: .generateBox(size: 0.12),
            materials: [SimpleMaterial(color: .blue, isMetallic: false)]
        )
        box.position = [0.25, 0, -0.5]
        content.add(box)

        // Green tall box
        let greenBox = ModelEntity(
            mesh: .generateBox(width: 0.08, height: 0.2, depth: 0.08),
            materials: [SimpleMaterial(color: .green, isMetallic: false)]
        )
        greenBox.position = [-0.25, 0, -0.5]
        content.add(greenBox)

        // Gray floor
        let floor = ModelEntity(
            mesh: .generatePlane(width: 1.0, depth: 1.0),
            materials: [SimpleMaterial(color: .gray, isMetallic: false)]
        )
        floor.position = [0, -0.15, -0.5]
        content.add(floor)
    }
}
