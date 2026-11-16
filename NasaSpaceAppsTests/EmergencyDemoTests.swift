import Testing
@testable import NasaSpaceApps

struct EmergencyDemoTests {
    @Test func emergencyReturnIsOneWayAndDoesNotIncludeScienceStop() throws {
        let grid = TerrainGrid(width: 2, height: 1, cellSizeMeters: 10,
                               elevationsMeters: [0, 0], sourceProduct: "synthetic-test")
        var settings = RouteConstraints()
        settings.scienceStopMinutes = 9999
        settings.scienceStopWatts = 9999
        let router = WeightedAStarRouter(constraints: settings)
        let comparison = try #require(router.emergencyReturn(on: grid, from: GridPoint(x: 1, y: 0),
            to: GridPoint(x: 0, y: 0), weights: RouteWeightPreset.balancedScience.weights))
        #expect(comparison.failureReason == nil)
        let result = comparison.routed
        let minutes = 10.0 / 0.85 / 60
        let energy = 420.0 * (minutes * 60) / 1000
        #expect(abs(result.traverseMinutes - minutes) < 0.0001)
        #expect(abs(result.energyKilojoules - energy) < 0.0001)
        #expect(abs(result.walkBackMarginPercent - (0.75 - energy / 3000) * 100) < 0.0001)
        #expect(router.emergencyLimitingResource(for: result) == "energy")
    }

    @Test func blockedReturnKeepsCrewPositionAndFailure() throws {
        let grid = TerrainGrid(width: 2, height: 1, cellSizeMeters: 8,
                               elevationsMeters: [0, 100], sourceProduct: "synthetic-test")
        let start = GridPoint(x: 1, y: 0)
        let comparison = try #require(WeightedAStarRouter().emergencyReturn(on: grid, from: start,
            to: GridPoint(x: 0, y: 0), weights: RouteWeightPreset.balancedScience.weights))
        #expect(comparison.origin == start)
        #expect(comparison.failureReason != nil)
        #expect(comparison.routed.path.isEmpty)
    }

    @Test @MainActor func demoFreezesCrewAndRestoresOriginalRoute() throws {
        let store = MissionStore()
        let original = try #require(store.routeComparison)
        try #require(original.routed.path.count > 1)
        let oldCrew = store.markerPositions["crew-01"]
        store.startEmergencyDemo()
        let demo = try #require(store.emergencyDemo)
        #expect(store.crewTelemetry[0].point == demo.crewPoint)
        #expect(store.routeComparison?.origin == demo.crewPoint)
        #expect(store.crewTelemetry[0].oxygenPercent == 75)
        #expect(abs(store.crewTelemetry[0].coolingWaterKilograms - 1.125) < 0.0001)
        #expect(store.crewTelemetry[0].walkBackMarginPercent == (demo.remainingReservePercent ?? 0))
        store.selectLandmark("altadena-boxwork")
        store.selectCrew("crew-01")
        #expect(store.isCrewCardVisible && !store.isLandmarkCardVisible)
        for stage in [MissionStage.tabletop, .drone, .helmet, .globe] {
            store.setStage(stage)
            #expect(store.crewTelemetry[0].point == demo.crewPoint)
            #expect(store.crewTelemetry[0].oxygenPercent == 75)
            #expect(store.routeComparison?.origin == demo.crewPoint)
        }
        store.moveMarker("crew-01", to: GridPoint(x: 0, y: 0))
        #expect(store.crewTelemetry[0].point == demo.crewPoint)
        store.resetEmergencyDemo()
        #expect(store.emergencyDemo == nil)
        #expect(store.routeComparison == original)
        #expect(store.markerPositions["crew-01"] == oldCrew)
        #expect(store.crewTelemetry[0].oxygenPercent == CrewTelemetry.demoCrew[0].oxygenPercent)
    }
}
