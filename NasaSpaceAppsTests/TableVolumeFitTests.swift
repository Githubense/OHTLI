import RealityKit
import simd
import Testing
@testable import NasaSpaceApps

struct TableVolumeFitTests {
    @Test func positiveDepthBoundsPlaceFlatTableLowAndForward() throws {
        let transform = try #require(TableVolumeFit.transform(
            viewMin: SIMD3(-0.7, -0.7, 0), viewMax: SIMD3(0.7, 0.7, 1.4),
            contentMin: SIMD3(-0.5, -0.08, -0.5), contentMax: SIMD3(0.5, 0.12, 0.5)))
        #expect(transform.translation.z >= 0.5 && transform.translation.z < 0.6)
        #expect(transform.translation.y < -0.4)
        #expect(transform.scale.x <= 0.84)
        let tableNormal = transform.rotation.act(SIMD3<Float>(0, 1, 0))
        #expect(simd_distance(tableNormal, SIMD3<Float>(0, 1, 0)) < 0.0001)
    }

    @Test func contentFitsMeasuredBoundsAtMultipleSizes() throws {
        for size: Float in [0.8, 1.05, 1.4] {
            let viewMin = SIMD3<Float>(repeating: -size / 2)
            let viewMax = SIMD3<Float>(repeating: size / 2)
            let contentMin = SIMD3<Float>(-0.5, -0.09, -0.5)
            let contentMax = SIMD3<Float>(0.5, 0.12, 0.5)
            let transform = try #require(TableVolumeFit.transform(viewMin: viewMin, viewMax: viewMax, contentMin: contentMin, contentMax: contentMax))
            for x in [contentMin.x, contentMax.x] {
                for y in [contentMin.y, contentMax.y] {
                    for z in [contentMin.z, contentMax.z] {
                        let point = transform.translation + transform.rotation.act(SIMD3<Float>(x, y, z) * transform.scale)
                        #expect(point.x >= viewMin.x + 0.039 && point.x <= viewMax.x - 0.039)
                        #expect(point.y >= viewMin.y + 0.039 && point.y <= viewMax.y - 0.039)
                        #expect(point.z >= viewMin.z + 0.039 && point.z <= viewMax.z - 0.039)
                    }
                }
            }
        }
    }
}
