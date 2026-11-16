import Foundation
import simd
import Testing
@testable import NasaSpaceApps

struct TerrainRouteGeometryTests {
    @Test func detailedRouteFollowsScaledDemAndRegistration() {
        let coarse = TerrainGrid(width: 2, height: 2, cellSizeMeters: 2, elevationsMeters: [0, 0, 0, 0], sourceProduct: "test")
        let detail = TerrainGrid(width: 3, height: 3, cellSizeMeters: 1, elevationsMeters: [0, 4, 8, 0, 4, 8, 0, 4, 8], sourceProduct: "test")
        let path = TerrainRouteGeometry.densify([GridPoint(x: 0, y: 1), GridPoint(x: 1, y: 1)], source: coarse, display: detail)
        #expect(path == [GridPoint(x: 0, y: 2), GridPoint(x: 1, y: 2), GridPoint(x: 2, y: 2)])
        let p = TerrainRouteGeometry.position(path[0], grid: detail, width: 0.88, depth: 0.88, heightScale: 0.00043, lift: 0.0025)
        #expect(abs(p.x + 0.44) < 0.000001)
        #expect(abs(p.z - 0.44) < 0.000001)
        #expect(abs(p.y - (Float(-4) * 0.00043 + 0.0025)) < 0.000001)
    }

    @Test func routeSegmentsAreClippedToTabletop() throws {
        let (a, b) = try #require(TerrainRouteGeometry.clippedSegment(from: SIMD3(-2, 0, 0), to: SIMD3(2, 4, 0), radius: 1))
        #expect(abs(a.x + 1) < 0.0001 && abs(b.x - 1) < 0.0001)
        #expect(abs(a.y - 1) < 0.0001 && abs(b.y - 3) < 0.0001)
        #expect(TerrainRouteGeometry.clippedSegment(from: SIMD3(2, 0, 2), to: SIMD3(3, 0, 2), radius: 1) == nil)
    }
}
