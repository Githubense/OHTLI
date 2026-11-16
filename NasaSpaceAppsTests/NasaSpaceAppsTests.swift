import Foundation
import RealityKit
import simd
import Testing
@testable import NasaSpaceApps

struct NasaSpaceAppsTests {
    @Test func aerialFramingIncludesBothRoutesAndLimitsZoom() {
        let frame = AerialOverview.frame(points: [GridPoint(x: 0, y: 10), GridPoint(x: 80, y: 20), GridPoint(x: 40, y: 60)], cellSize: 8, fallback: GridPoint(x: 0, y: 0))
        #expect(frame.center == GridPoint(x: 40, y: 35))
        #expect(frame.altitude >= 544)
        #expect(AerialOverview.altitude(frame.altitude, zoom: 100) == AerialOverview.altitude(frame.altitude, zoom: AerialOverview.zoomRange.upperBound))
        #expect(AerialOverview.altitude(frame.altitude, zoom: 0) <= 1800)
        #expect(AerialOverview.frame(points: [], cellSize: 1, fallback: GridPoint(x: 3, y: 4)).center == GridPoint(x: 3, y: 4))
    }
    @Test @MainActor func nativeGaleGridMatchesThreeMeterGridAndMeshEdges() throws {
        let asset = try MarsDataCatalog.loadBundled()
        let native = try #require(asset.nativeTerrain)
        let detail = try #require(asset.detailedTerrain)
        #expect(native.width == 1015)
        #expect(native.height == 1015)
        for p in [GridPoint(x: 0, y: 0), GridPoint(x: 169, y: 169), GridPoint(x: 338, y: 338), GridPoint(x: 54, y: 210)] {
            #expect(native.elevation(at: GridPoint(x: p.x * 3, y: p.y * 3)) == detail.elevation(at: p))
        }
        let samples = TerrainMeshFactory.adaptiveSampleIndices(native.width)
        #expect(samples.first == 0 && samples.last == 1014)
        #expect((0...338).allSatisfy { samples.contains($0 * 3) })
        #expect((357...657).allSatisfy { samples.contains($0) })
        let size = Float(Double(native.width - 1) * native.cellSizeMeters)
        let mesh = TerrainMeshFactory.makeMeshData(grid: native, widthMeters: size, depthMeters: size, heightScale: 1, circularRadiusMeters: size, adaptiveNativeDetail: true)
        #expect(mesh.textureCoordinates.first == SIMD2<Float>(0, 0))
        #expect(mesh.textureCoordinates.last == SIMD2<Float>(1, 1))
    }
    @Test func tabletopTerrainHasCompleteCircularEdgeAndRegisteredUVs() {
        let grid = TerrainGrid(width: 21, height: 21, cellSizeMeters: 1,
                               elevationsMeters: Array(repeating: 0, count: 441), sourceProduct: "circle-test")
        let mesh = TerrainMeshFactory.makeMeshData(grid: grid, widthMeters: 0.88, depthMeters: 0.88,
                                                   heightScale: 0.00043, circularRadiusMeters: 0.44)
        var area: Float = 0
        for i in stride(from: 0, to: mesh.indices.count, by: 3) {
            let a = mesh.vertices[Int(mesh.indices[i])]
            let b = mesh.vertices[Int(mesh.indices[i + 1])]
            let c = mesh.vertices[Int(mesh.indices[i + 2])]
            area += abs((b.x - a.x) * (c.z - a.z) - (b.z - a.z) * (c.x - a.x)) / 2
            for index in mesh.indices[i..<(i + 3)] {
                let vertex = mesh.vertices[Int(index)]
                let uv = mesh.textureCoordinates[Int(index)]
                #expect(hypot(vertex.x, vertex.z) <= 0.44001)
                #expect(abs(uv.x - (vertex.x / 0.88 + 0.5)) < 0.00001)
                #expect(abs(uv.y - (vertex.z / 0.88 + 0.5)) < 0.00001)
            }
        }
        #expect(abs(area - Float.pi * 0.44 * 0.44) < 0.0002)
    }

    @Test func immersiveHorizonIsAClosedCircleJoinedToMeasuredCrop() {
        let grid = TerrainGrid(width: 5, height: 5, cellSizeMeters: 1,
                               elevationsMeters: Array(repeating: 0, count: 25), sourceProduct: "circular-horizon-test")
        let skirt = TerrainMeshFactory.makeHorizonSkirtData(
            grid: grid, innerWidthMeters: 2, innerDepthMeters: 2,
            ringWidthsMeters: [10, 20], angularSegments: 32)
        #expect(skirt.vertices.count == 96)
        #expect(skirt.indices.count == 32 * 2 * 6)
        let innerRing = skirt.vertices.prefix(32)
        #expect(innerRing.allSatisfy { abs(hypot($0.x, $0.z) - 1) < 0.0001 })
        #expect(abs(hypot(skirt.vertices[64].x, skirt.vertices[64].z) - 21) < 0.0001)
        #expect(skirt.indices.contains(31) && skirt.indices.contains(0))
        #expect(skirt.vertices.allSatisfy { $0.x.isFinite && $0.y.isFinite && $0.z.isFinite })
    }

    @Test func immersiveSkyMeshOnlyCoversTheUpperHemisphere() {
        let sky = TerrainMeshFactory.makeSkyHemisphereData(radius: 30, longitudeSegments: 32, latitudeSegments: 8)
        #expect(sky.vertices.count == 33 * 9)
        #expect(sky.indices.count == 32 * 8 * 6)
        #expect(sky.indices.allSatisfy { Int($0) < sky.vertices.count })
        #expect(sky.vertices.allSatisfy { $0.y >= -0.0001 })
        #expect(sky.vertices.contains { abs($0.y) < 0.0001 && abs(hypot($0.x, $0.z) - 30) < 0.0001 })
        #expect(sky.textureCoordinates.allSatisfy { $0.y >= 0 && $0.y <= 0.5 })
    }

    @Test func tabletopFitsTheActualPositiveDepthVolume() throws {
        let transform = try #require(TableVolumeFit.transform(
            viewMin: SIMD3(-0.7, -0.7, 0), viewMax: SIMD3(0.7, 0.7, 1.4),
            contentMin: SIMD3(-0.5, -0.08, -0.5), contentMax: SIMD3(0.5, 0.12, 0.5)))
        #expect(simd_distance(transform.rotation.act(SIMD3<Float>(0, 1, 0)), SIMD3<Float>(0, 1, 0)) < 0.0001)
        #expect(transform.scale.x >= 0.84)
        #expect(transform.translation.y < -0.4)
        #expect(transform.translation.z > 0.5)
        for angle in stride(from: Float(0), to: 2 * .pi, by: .pi / 32) {
            let point = transform.translation + transform.rotation.act(SIMD3<Float>(0.49 * cos(angle), 0, 0.49 * sin(angle)) * transform.scale)
            #expect(abs(point.x) <= 0.66 && abs(point.y) <= 0.66 && point.z >= 0.04 && point.z <= 1.36)
        }
    }

    @Test func galeGlobePinsFanOutAndRemainOutsideTheSphere() {
        let surface = SIMD3<Float>(0, 0, GlobePinLayout.globeRadiusMeters)
        let identifiers = ["mount-sharp-boxwork", "altadena-boxwork", "airlock-alpha"]
        let positions = identifiers.map {
            GlobePinLayout.beaconPosition(markerID: $0, surfacePosition: surface)
        }
        let nearestPairDistance = positions.indices.flatMap { first in
            positions.indices.compactMap { second in
                second > first ? simd_distance(positions[first], positions[second]) : nil
            }
        }.min() ?? 0

        #expect(nearestPairDistance > GlobePinLayout.hitRadiusMeters * 2)
        #expect(positions.allSatisfy { abs(simd_length($0) - GlobePinLayout.beaconCenterRadiusMeters) < 0.0001 })
    }

    @Test @MainActor func sceneReadinessIsIndependent() {
        let store = MissionStore()
        #expect(store.terrainAsset != nil)
        #expect(store.isReady(for: .globe))
        #expect(!store.isReady(for: .tabletop))
        #expect(!store.isReady(for: .drone))
        store.isPlanningSceneReady = true
        #expect(store.isReady(for: .tabletop))
        #expect(!store.isReady(for: .drone))
        store.isImmersiveTerrainReady = true
        #expect(store.isReady(for: .helmet))
        store.isPlanningSceneReady = false
        #expect(!store.isReady(for: .tabletop))
        #expect(store.isReady(for: .drone))
    }

    @Test func globeTextureCoordinatesMatchLandmarkGeography() {
        // Gale's longitude is at the center-facing meridian. UV 0 and 1 are
        // the same longitude, while the top and bottom represent the poles.
        let gale = GlobeCoordinates.normal(latitudeDegrees: -4.7, longitudeDegreesEast: 137.4)
        let matchingUV = GlobeCoordinates.normal(textureU: 137.4 / 360, textureV: (90 + 4.7) / 180)
        #expect(simd_distance(gale, matchingUV) < 0.00001)
        #expect(simd_distance(GlobeCoordinates.normal(textureU: 0, textureV: 0.5), GlobeCoordinates.normal(textureU: 1, textureV: 0.5)) < 0.00001)
        #expect(GlobeCoordinates.normal(textureU: 0.2, textureV: 0).y > 0.9999)
        #expect(GlobeCoordinates.normal(textureU: 0.2, textureV: 1).y < -0.9999)
    }

    @Test func selectedCalloutClearsGlobeAtCenterAndLimb() {
        let viewer = SIMD3<Float>(0, 0, 1.2)
        let view = simd_normalize(viewer)
        for marker in [SIMD3<Float>(0, 0, 0.363), SIMD3<Float>(0.35, 0, 0.096)] {
            let callout = marker + GlobePinLayout.calloutOffset(markerPosition: marker, viewerPosition: viewer)
            #expect(simd_dot(callout, view) >= GlobePinLayout.globeRadiusMeters + 0.0249)
        }
    }

    @Test func idleMotionLevelsTiltWithoutResettingOrientation() {
        #expect(MarsRotation.presentationRadiansPerSecond > MarsRotation.radiansPerSecond)
        #expect(MarsRotation.leveledPitch(0.8, after: 1) > 0)
        #expect(MarsRotation.leveledPitch(0.8, after: 1) < 0.8)
        #expect(MarsRotation.leveledPitch(-0.8, after: 1) < 0)
    }

    @Test func globePlacementUsesEyeHeightAndHorizontalHeading() {
        let eye = SIMD3<Float>(3, 1.7, -2)
        let position = GlobePlacement.position(eye: eye, direction: SIMD3(1, -0.8, 0))
        #expect(simd_distance(position, SIMD3(4.2, 1.6, -2)) < 0.00001)
        let lookingUp = GlobePlacement.position(eye: eye, direction: SIMD3(0, 1, 0))
        #expect(simd_distance(lookingUp, SIMD3(3, 1.6, -3.2)) < 0.00001)
    }

    @Test func globeMomentumDampsSmoothly() {
        let halfSecond = MarsRotation.damping(after: 0.5)
        #expect(halfSecond > 0 && halfSecond < 1)
        #expect(abs(halfSecond * halfSecond - MarsRotation.damping(after: 1)) < 0.000001)
        #expect(MarsRotation.damping(after: 3) < 0.001)
        #expect(MarsRotation.damping(after: 0) == 1)
    }

    @Test func idleGlobeRotationCompletesOneTurnPerMartianSol() {
        #expect(abs(MarsRotation.radiansPerSecond * MarsRotation.solDurationSeconds - 2 * Double.pi) < 0.000_001)
    }

    @Test func helmetTerrainWaypointSitsDirectlyBelowTheEyeOrigin() {
        let waypoint = SIMD3<Float>(12, 3.4, -8)
        let terrainTranslation = HelmetTerrainPlacement.translation(for: waypoint)
        let translatedWaypoint = waypoint + terrainTranslation

        #expect(abs(translatedWaypoint.x) < 0.000_001)
        #expect(abs(translatedWaypoint.y + HelmetTerrainPlacement.eyeHeightMeters) < 0.000_001)
        #expect(abs(translatedWaypoint.z) < 0.000_001)
    }

    @Test func immersiveTerrainPlacementKeepsRequestedClearanceAtAnyEyePose() {
        let eye = SIMD3<Float>(2.5, 1.6, -4)
        let point = SIMD3<Float>(30, -7, -22)
        for clearance in [Float(1.8), 20] {
            let placed = point + ImmersiveTerrainPlacement.translation(eye: eye, terrainPoint: point, clearance: clearance)
            #expect(simd_distance(placed, eye + SIMD3<Float>(0, -clearance, 0)) < 0.00001)
        }
    }

    @Test func bundledTerrainCarriesSourceProvenance() throws {
        let asset = try MarsDataCatalog.loadBundled()
        #expect(asset.terrain.width == 128)
        #expect(asset.terrain.height == 128)
        #expect(abs(asset.terrain.cellSizeMeters - 8.094104) < 0.000001)
        #expect(asset.metadata.sourceProduct == "DTEEC_040770_1755_039280_1755_U01")
        #expect(asset.metadata.registrationNote.contains("not confirmed to overlap"))
        #expect(abs(asset.metadata.sourceLocation.latitudeCenterDegrees - -4.687699920663519) < 0.0000001)
        #expect(abs(asset.metadata.sourceLocation.longitudeCenterDegreesEast - 137.3888819769589) < 0.0000001)
        #expect(asset.metadata.registeredOrthophoto?.projectionAlignedToDTM == true)
        #expect(asset.metadata.registeredOrthophoto?.cropSizePixels.width == 4065)
        #expect(asset.detailedTerrain?.width == 339)
        #expect(abs((asset.detailedTerrain?.cellSizeMeters ?? 0) - 3.035289) < 0.000001)
        #expect(asset.detailedMetadata?.sourceProduct == asset.metadata.sourceProduct)
    }

    @Test @MainActor func bundledCaseStudyProducesRecomputedRoute() {
        let store = MissionStore()
        #expect(store.routeComparison != nil)
        #expect(store.routeComparison?.routed.usesScenarioOverlay == true)
        #expect(store.routeComparison.map { $0.routed.distanceMeters > $0.straightLineDistanceMeters } == true)
        #expect(store.routeComparison?.straightLineResult.isSafe == false)
        #expect(store.routeComparison?.straightLineResult.safetyViolations.contains(where: { $0.contains("obstacle overlay") }) == true)
    }

    @Test @MainActor func movingDestinationRecalculatesRouteFromTheNewTerrainPoint() throws {
        let store = MissionStore()
        let original = try #require(store.routeComparison)
        let destination = original.routed.path[original.routed.path.count / 2]

        store.moveMarker("altadena-boxwork", to: destination)

        #expect(store.markerPositions["altadena-boxwork"] == destination)
        #expect(store.routeComparison?.destination == destination)
        #expect(store.routeComparison != original)
    }

    @Test @MainActor func jezeroRemainsAGlobeOnlyMarkerWithoutGaleTerrainClaim() {
        let store = MissionStore()
        store.selectLandmark("jezero-crater")

        #expect(store.selectedLandmarkID == "jezero-crater")
        #expect(store.hasGaleTerrainContext == false)
        #expect(store.stage == .globe)
    }

    @Test @MainActor func routeAndLayerStateRemainSharedAcrossMVPStages() {
        let store = MissionStore()
        let route = store.routeComparison
        store.toggleLayer(.slopeTraction)
        store.toggleLayer(.optical)

        for stage in [MissionStage.tabletop, .drone, .helmet] {
            store.setStage(stage)
            #expect(store.activeLayers.contains(.slopeTraction))
            #expect(!store.activeLayers.contains(.optical))
            #expect(store.routeComparison == route)
        }

        store.toggleLayer(.optical)
        #expect(store.activeLayers.contains(.optical))
        #expect(store.routeComparison == route)
    }

    @Test @MainActor func crewCardAppearsOnSelectionAndCanBeDismissed() {
        let store = MissionStore()
        #expect(store.isCrewCardVisible == false)

        store.selectCrew("crew-02")
        #expect(store.selectedCrewID == "crew-02")
        #expect(store.isCrewCardVisible)

        store.dismissCrewCard()
        #expect(store.isCrewCardVisible == false)
    }

    @Test @MainActor func playbackAdvancesCrewPositionFromSharedTimestamp() async throws {
        let store = MissionStore()
        let startingPoint = store.crewTelemetry[0].point
        store.setPlayback(true)
        try await Task.sleep(for: .milliseconds(1_100))
        #expect(store.playbackProgress > 0)
        #expect(store.crewTelemetry[0].point != startingPoint)
        store.setPlayback(false)
    }

    @Test func weightedAStarIsDeterministicAndAvoidsScenarioWall() throws {
        let grid = flatGrid()
        let router = WeightedAStarRouter()
        let origin = GridPoint(x: 18, y: 64)
        let destination = GridPoint(x: 92, y: 64)
        let first = try #require(router.compare(on: grid, from: origin, to: destination, weights: RouteWeightPreset.balancedScience.weights))
        let second = try #require(router.compare(on: grid, from: origin, to: destination, weights: RouteWeightPreset.balancedScience.weights))

        #expect(first == second)
        #expect(first.routed.distanceMeters > first.straightLineDistanceMeters)
        #expect(first.routed.walkBackMarginPercent >= 50)
        #expect(first.straightLineResult.isSafe == false)
        #expect(first.straightLineDistanceMeters == first.straightLineResult.distanceMeters)
        #expect(first.straightLineResult.safetyViolations.contains(where: { $0.contains("obstacle overlay") }))
        let sandStoppingDistance = 1.15 * 1.15 / (2 * 0.25 * 3.72076)
        #expect(abs(first.straightLineResult.emergencyBrakingDistanceMeters - sandStoppingDistance) < 0.001)
        #expect(first.routed.emergencyBrakingDistanceMeters < first.straightLineResult.emergencyBrakingDistanceMeters)
        #expect(first.routed.path.allSatisfy { !(45...55).contains($0.x) || !(54...73).contains($0.y) })
        #expect(first.straightLinePath.contains { (45...55).contains($0.x) && (54...73).contains($0.y) })
    }

    @Test func slopeAndResourceGatesRejectUnsafeRoutes() {
        var elevations = Array(repeating: Float(0), count: 25)
        elevations[2 * 5 + 2] = 100
        let steepGrid = TerrainGrid(width: 5, height: 5, cellSizeMeters: 8, elevationsMeters: elevations, sourceProduct: "synthetic-test-grid")
        let steepRoute = WeightedAStarRouter().route(
            on: steepGrid,
            from: GridPoint(x: 1, y: 2),
            to: GridPoint(x: 2, y: 2),
            weights: RouteWeightPreset.balancedScience.weights
        )
        #expect(steepRoute == nil)

        var lowReserveConstraints = RouteConstraints()
        lowReserveConstraints.demoEnergyCapacityKilojoules = 1
        let lowReserveRouter = WeightedAStarRouter(constraints: lowReserveConstraints)
        let lowReserveRoute = lowReserveRouter.route(
            on: flatGrid(),
            from: GridPoint(x: 18, y: 64),
            to: GridPoint(x: 92, y: 64),
            weights: RouteWeightPreset.suitSafety.weights
        )
        #expect(lowReserveRoute == nil)

        var lowCO2Capacity = RouteConstraints()
        lowCO2Capacity.demoCO2ScrubberDurationMinutes = 1
        let lowCO2Route = WeightedAStarRouter(constraints: lowCO2Capacity).route(
            on: flatGrid(),
            from: GridPoint(x: 18, y: 64),
            to: GridPoint(x: 92, y: 64),
            weights: RouteWeightPreset.suitSafety.weights
        )
        #expect(lowCO2Route == nil)
    }

    @Test func flatRouteReserveIncludesReturnAndScienceStop() throws {
        let grid = TerrainGrid(width: 2, height: 1, cellSizeMeters: 10,
                               elevationsMeters: [0, 0], sourceProduct: "synthetic-budget-test")
        let result = try #require(WeightedAStarRouter().route(
            on: grid, from: GridPoint(x: 0, y: 0), to: GridPoint(x: 1, y: 0),
            weights: RouteWeightPreset.balancedScience.weights))
        let oneWayMinutes = 10.0 / 0.85 / 60
        let expectedOxygenReserve = (1 - (2 * oneWayMinutes + 30) / 150) * 100
        #expect(abs(result.traverseMinutes - oneWayMinutes) < 0.0001)
        #expect(abs(result.walkBackMarginPercent - expectedOxygenReserve) < 0.0001)
    }

    @Test func edgeSlopeGateRejectsACliffThatEndpointSamplesUnderestimate() {
        var elevations = Array(repeating: Float(0), count: 3 * 3)
        elevations[1 * 3 + 2] = 5
        let grid = TerrainGrid(width: 3, height: 3, cellSizeMeters: 8, elevationsMeters: elevations, sourceProduct: "synthetic-edge-slope-test")
        let route = WeightedAStarRouter().route(
            on: grid,
            from: GridPoint(x: 1, y: 1),
            to: GridPoint(x: 2, y: 1),
            weights: RouteWeightPreset.balancedScience.weights
        )

        #expect(atan2(5.0, 8.0) * 180 / .pi > 20)
        #expect(route == nil)
    }

    @Test func stormRouteReturnsCrewToHabitatWithDisclosure() throws {
        let comparison = try #require(WeightedAStarRouter().compare(
            on: flatGrid(),
            from: GridPoint(x: 72, y: 64),
            to: GridPoint(x: 18, y: 64),
            weights: RouteWeightPreset.solarEmergency.weights,
            solarStormActive: true
        ))
        #expect(comparison.isWalkBack)
        #expect(comparison.routed.path.first == GridPoint(x: 72, y: 64))
        #expect(comparison.routed.path.last == GridPoint(x: 18, y: 64))
        #expect(comparison.routed.warning?.contains("scenario-only") == true)

        var shortShelterWindow = RouteConstraints()
        shortShelterWindow.solarShelterLimitMinutes = 1
        let outsideShelterWindow = WeightedAStarRouter(constraints: shortShelterWindow).route(
            on: flatGrid(),
            from: GridPoint(x: 72, y: 64),
            to: GridPoint(x: 18, y: 64),
            weights: RouteWeightPreset.solarEmergency.weights,
            solarStormActive: true
        )
        #expect(outsideShelterWindow?.warning?.contains("shelter availability is not modeled") == true)
    }

    @Test func missionSnapshotRoundTripsAndEqualRevisionCanBeApplied() async throws {
        let snapshot = MissionStateSnapshot(
            revision: 0,
            stage: .habitat,
            globeRotationOffset: 1.25,
            selectedLandmarkID: "mount-sharp-boxwork",
            selectedCrewID: "crew-02",
            isCrewCardVisible: true,
            isLandmarkCardVisible: false,
            activeLayers: [.radioLineOfSight, .thermalShadow],
            selectedGlobeLayer: .themisInfrared,
            markerPositions: ["airlock-alpha": GridPoint(x: 9, y: 21)],
            playbackSpeed: 5,
            selectedPlaybackProgress: 0.42,
            inspectionOffset: GridPoint(x: 2, y: 3),
            helmetWaypoint: GridPoint(x: 11, y: 18),
            weightPreset: .solarEmergency,
            solarStormActive: true,
            activeAlert: .solarParticleEvent,
            radioTransmission: nil,
            liveEVAPlayback: false,
            playbackStartTime: nil,
            routeComparison: nil
        )
        let encoded = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(MissionStateSnapshot.self, from: encoded)
        #expect(decoded == snapshot)

        let store = await MainActor.run { MissionStore() }
        await MainActor.run { store.applyRemoteSnapshot(snapshot) }
        let stage = await MainActor.run { store.stage }
        #expect(stage == .habitat)
        let sharedRotation = await MainActor.run { store.globeRotationOffset }
        let sharedLayer = await MainActor.run { store.selectedGlobeLayer }
        let sharedMarker = await MainActor.run { store.markerPositions["airlock-alpha"] }
        #expect(sharedRotation == 1.25)
        #expect(sharedLayer == .themisInfrared)
        #expect(sharedMarker == GridPoint(x: 9, y: 21))

        var radioSnapshot = snapshot
        radioSnapshot.solarStormActive = false
        radioSnapshot.activeAlert = nil
        radioSnapshot.radioTransmission = RadioTransmission(
            id: UUID(uuidString: "5BB8C21A-9E51-48E3-AB14-390C4F688AF2")!,
            callsign: "EVA-02",
            transcript: "Waypoint check.",
            endsAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
        let immutableRadioSnapshot = radioSnapshot
        let radioData = try JSONEncoder().encode(immutableRadioSnapshot)
        let decodedRadio = try JSONDecoder().decode(MissionStateSnapshot.self, from: radioData)
        #expect(decodedRadio.radioTransmission == immutableRadioSnapshot.radioTransmission)
        await MainActor.run { store.applyRemoteSnapshot(immutableRadioSnapshot) }
        let remoteRadio = await MainActor.run { store.remoteRadioTransmission }
        #expect(remoteRadio?.callsign == "EVA-02")
    }

    private func flatGrid() -> TerrainGrid {
        TerrainGrid(
            width: 128,
            height: 128,
            cellSizeMeters: 8.094104,
            elevationsMeters: Array(repeating: 0, count: 128 * 128),
            sourceProduct: "synthetic-flat-test-grid"
        )
    }
}
