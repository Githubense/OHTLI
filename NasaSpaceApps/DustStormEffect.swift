import RealityKit
import UIKit

/// Decorative simulated dust, kept near the tabletop center and never weather data.
@MainActor
enum DustStormEffect {
    static func make(reduceMotion: Bool) -> Entity {
        let root = Entity()
        root.name = "simulated-dust-effect"
        root.position = SIMD3<Float>(0, 0.045, 0)
        if reduceMotion {
            let material = UnlitMaterial(color: UIColor(red: 0.75, green: 0.44, blue: 0.23, alpha: 0.45))
            for (x, z) in [(-0.08, -0.04), (-0.03, 0.02), (0.04, -0.03), (0.08, 0.04)] {
                let grain = ModelEntity(mesh: .generateSphere(radius: 0.003), materials: [material])
                grain.position = SIMD3<Float>(Float(x), 0.005, Float(z))
                root.addChild(grain)
            }
        } else {
            var emitter = ParticleEmitterComponent()
            emitter.emitterShapeSize = SIMD3<Float>(0.16, 0.01, 0.16)
            emitter.speed = 0.005
            emitter.speedVariation = 0
            emitter.mainEmitter.birthRate = 12
            emitter.mainEmitter.size = 0.002
            // A particle can travel at most 1 cm from the 8 cm emitter
            // footprint during its lifetime, safely inside the 44 cm map.
            emitter.mainEmitter.lifeSpan = 2
            emitter.mainEmitter.lifeSpanVariation = 0
            emitter.mainEmitter.acceleration = .zero
            emitter.mainEmitter.noiseStrength = 0
            emitter.mainEmitter.attractionStrength = 0
            emitter.mainEmitter.vortexStrength = 0
            root.components.set(emitter)
        }
        return root
    }
}
