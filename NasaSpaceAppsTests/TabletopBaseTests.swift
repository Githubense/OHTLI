import Testing
@testable import NasaSpaceApps

struct TabletopBaseTests {
    @Test func baseSitsBelowLowestTerrainPost() {
        let grid = TerrainGrid(width: 3, height: 3, cellSizeMeters: 1,
                               elevationsMeters: [100, 99, 98, 97, 101, 102, 99, 103, 104],
                               sourceProduct: "synthetic-test")
        let scale: Float = 0.00043
        let diskTop = TerrainMeshFactory.tabletopBaseCenterY(grid: grid, heightScale: scale) + 0.035 / 2
        let lowestTerrain = (Float(97) - Float(101)) * scale
        #expect(abs((lowestTerrain - diskTop) - 0.003) < 0.000001)
    }

    @Test @MainActor func baseDoesNotCoverBundledGaleTerrain() throws {
        let asset = try MarsDataCatalog.loadBundled()
        let grid = asset.detailedTerrain ?? asset.terrain
        let center = Float(grid.elevation(at: GridPoint(x: grid.width / 2, y: grid.height / 2)))
        let lowest = try #require(grid.elevationsMeters.min())
        let lowestTerrain = (lowest - center) * 0.00043
        let diskTop = TerrainMeshFactory.tabletopBaseCenterY(grid: grid, heightScale: 0.00043) + 0.035 / 2
        #expect(diskTop < lowestTerrain)
    }
}
