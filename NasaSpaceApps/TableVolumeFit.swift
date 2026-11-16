import RealityKit
import simd

/// Fits the complete horizontal planning content into the system's current volume,
/// which can differ from a WindowGroup's requested initial dimensions.
nonisolated enum TableVolumeFit {
    static func transform(viewMin: SIMD3<Float>, viewMax: SIMD3<Float>,
                          contentMin: SIMD3<Float>, contentMax: SIMD3<Float>) -> Transform? {
        let values = [viewMin.x, viewMin.y, viewMin.z, viewMax.x, viewMax.y, viewMax.z,
                      contentMin.x, contentMin.y, contentMin.z, contentMax.x, contentMax.y, contentMax.z]
        guard values.allSatisfy(\.isFinite),
              viewMax.x > viewMin.x, viewMax.y > viewMin.y, viewMax.z > viewMin.z,
              contentMax.x >= contentMin.x, contentMax.y >= contentMin.y, contentMax.z >= contentMin.z else { return nil }
        // Include the circular disk and space above it for markers even while
        // scene attachments are being assembled.
        let localMin = simd_min(contentMin, SIMD3<Float>(-0.50, -0.08, -0.50))
        let localMax = simd_max(contentMax, SIMD3<Float>(0.50, 0.12, 0.50))
        let rotation = simd_quatf(angle: 0, axis: SIMD3<Float>(1, 0, 0))
        var rotatedMin = SIMD3<Float>(repeating: .infinity)
        var rotatedMax = SIMD3<Float>(repeating: -.infinity)
        for x in [localMin.x, localMax.x] {
            for y in [localMin.y, localMax.y] {
                for z in [localMin.z, localMax.z] {
                    let p = rotation.act(SIMD3<Float>(x, y, z))
                    rotatedMin = simd_min(rotatedMin, p)
                    rotatedMax = simd_max(rotatedMax, p)
                }
            }
        }
        let margin: Float = 0.04
        let available = viewMax - viewMin - SIMD3<Float>(repeating: margin * 2)
        guard available.x > 0, available.y > 0, available.z > 0 else { return nil }
        let extent = rotatedMax - rotatedMin
        guard extent.x > 0, extent.y > 0, extent.z > 0 else { return nil }
        // Keep the table comfortably framed when SwiftUI reports a volume
        // whose scene-space depth starts at zero instead of being centred there.
        let scale = min(0.84, available.x / extent.x, available.y / extent.y, available.z / extent.z)
        let viewCenter = (viewMin + viewMax) / 2
        // In RealityKit +z points toward the viewer. Choose the rear of the
        // measured volume, then clamp using the complete rotated bounds. Keep
        // the flat map low enough to read from above and toward the front of
        // the volume, without changing the system-managed room pose.
        let desired = SIMD3<Float>(viewCenter.x, viewCenter.y - 0.46, viewMin.z + margin + 0.50)
        let lower = viewMin + SIMD3<Float>(repeating: margin) - rotatedMin * scale
        let upper = viewMax - SIMD3<Float>(repeating: margin) - rotatedMax * scale
        let translation = simd_min(simd_max(desired, lower), upper)
        return Transform(scale: SIMD3<Float>(repeating: scale), rotation: rotation, translation: translation)
    }
}
