import CoreGraphics

import Foundation
import Testing
@testable import NasaSpaceApps

struct TerrainMapCoordinatesTests {
    private let grid = TerrainGrid(width: 128, height: 128, cellSizeMeters: 8,
                                   elevationsMeters: Array(repeating: 0, count: 128 * 128), sourceProduct: "test")

    @Test func conversionUsesActualRenderedSize() {
        for side in [CGFloat(420), 480] {
            let size = CGSize(width: side, height: side)
            #expect(TerrainMapCoordinates.gridPoint(at: CGPoint(x: side / 2, y: side / 2), size: size, grid: grid) == GridPoint(x: 64, y: 64))
            #expect(TerrainMapCoordinates.gridPoint(at: CGPoint(x: side * 0.75, y: side / 2), size: size, grid: grid) == GridPoint(x: 95, y: 64))
            #expect(TerrainMapCoordinates.gridPoint(at: .zero, size: size, grid: grid) == nil)
            let edge = TerrainMapCoordinates.gridPoint(at: CGPoint(x: side * 2, y: side / 2), size: size, grid: grid, clampToCircle: true)
            #expect(edge == GridPoint(x: 126, y: 64))
        }
    }

    @Test func emptySizeIsNotInteractive() {
        #expect(TerrainMapCoordinates.gridPoint(at: .zero, size: .zero, grid: grid) == nil)
    }
}
