import Foundation
import simd

/// Terrain coordinates shared by the visible tabletop routes and the DEM mesh.
nonisolated enum TerrainRouteGeometry {
    static func position(_ point: GridPoint, grid: TerrainGrid, width: Float, depth: Float,
                         heightScale: Float, lift: Float) -> SIMD3<Float> {
        let x = Float(point.x) / Float(grid.width - 1) * width - width / 2
        let z = Float(point.y) / Float(grid.height - 1) * depth - depth / 2
        return SIMD3(x, Float(grid.relativeElevation(at: point)) * heightScale + lift, z)
    }

    /// Sample the higher-resolution terrain between route-grid waypoints.
    static func densify(_ points: [GridPoint], source: TerrainGrid, display: TerrainGrid) -> [GridPoint] {
        guard source.width > 1, source.height > 1, display.width > 1, display.height > 1 else { return [] }
        let converted = points.map { point in
            GridPoint(x: Int((Double(point.x) / Double(source.width - 1) * Double(display.width - 1)).rounded()),
                      y: Int((Double(point.y) / Double(source.height - 1) * Double(display.height - 1)).rounded()))
        }
        guard let first = converted.first else { return [] }
        var result = [first]
        for (a, b) in zip(converted, converted.dropFirst()) {
            let steps = max(abs(b.x - a.x), abs(b.y - a.y))
            guard steps > 0 else { continue }
            for i in 1...steps {
                let t = Double(i) / Double(steps)
                let point = GridPoint(x: Int((Double(a.x) + Double(b.x - a.x) * t).rounded()),
                                      y: Int((Double(a.y) + Double(b.y - a.y) * t).rounded()))
                if result.last != point { result.append(point) }
            }
        }
        return result
    }

    static func clippedSegment(from a: SIMD3<Float>, to b: SIMD3<Float>, radius: Float) -> (SIMD3<Float>, SIMD3<Float>)? {
        guard radius > 0 else { return nil }
        let p = SIMD2(a.x, a.z), d = SIMD2(b.x - a.x, b.z - a.z)
        let aa = simd_dot(d, d)
        guard aa > 0 else { return nil }
        let bb = 2 * simd_dot(p, d), cc = simd_dot(p, p) - radius * radius
        let discriminant = bb * bb - 4 * aa * cc
        guard discriminant >= 0 else { return nil }
        let root = sqrt(discriminant)
        let lo = max(Float(0), (-bb - root) / (2 * aa))
        let hi = min(Float(1), (-bb + root) / (2 * aa))
        guard lo < hi else { return nil }
        return (a + (b - a) * lo, a + (b - a) * hi)
    }
}
