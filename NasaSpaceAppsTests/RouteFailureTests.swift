import Testing
@testable import NasaSpaceApps

struct RouteFailureTests {
    private let grid = TerrainGrid(width: 5, height: 3, cellSizeMeters: 10,
                                   elevationsMeters: Array(repeating: 0, count: 15), sourceProduct: "test")
    private let weights = RouteWeightPreset.balancedScience.weights

    @Test func blockedEndpointsAndPathsPreserveDirectComparison() throws {
        var overlay = DemoTerrainOverlay()
        overlay.obstacleX = 2...2
        overlay.obstacleY = 0...2
        let router = WeightedAStarRouter(overlay: overlay)
        let blocked = try #require(router.compare(on: grid, from: GridPoint(x: 2, y: 1),
                                                  to: GridPoint(x: 4, y: 1), weights: weights))
        #expect(blocked.failureReason == .blockedEndpoint)
        #expect(blocked.routed.path.isEmpty)
        #expect(!blocked.routed.isSafe)
        #expect(blocked.straightLinePath.count == 3)

        let separated = try #require(router.compare(on: grid, from: GridPoint(x: 0, y: 1),
                                                    to: GridPoint(x: 4, y: 1), weights: weights))
        #expect(separated.failureReason == .noPassablePath)
        #expect(separated.straightLinePath.count == 5)
    }

    @Test func rejectedCandidatesDoNotEraseDirectLine() throws {
        var constraints = RouteConstraints()
        constraints.demoEnergyCapacityKilojoules = 1
        let router = WeightedAStarRouter(constraints: constraints)
        let comparison = try #require(router.compare(on: grid, from: GridPoint(x: 0, y: 1),
                                                      to: GridPoint(x: 4, y: 1), weights: weights))
        #expect(comparison.failureReason == .candidatesRejected)
        #expect(comparison.routed.path.isEmpty)
        #expect(comparison.straightLinePath.count == 5)
        #expect(router.compare(on: grid, from: GridPoint(x: 0, y: 0),
                               to: GridPoint(x: 0, y: 0), weights: weights) == nil)
    }
}
