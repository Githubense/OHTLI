import Foundation
import simd

/// Separates co-located Gale pins at globe scale while keeping their leader stems attached
/// to the source coordinates on the sphere.
nonisolated enum GlobePinLayout {
    static let globeRadiusMeters: Float = 0.35
    static let beaconCenterRadiusMeters: Float = 0.363
    static let hitRadiusMeters: Float = 0.023

    static func tangentOffset(for markerID: String) -> SIMD2<Float> {
        switch markerID {
        case "mount-sharp-boxwork": SIMD2(-0.051, 0.014)
        case "altadena-boxwork": SIMD2(0, 0.057)
        case "airlock-alpha": SIMD2(0.051, 0.014)
        case "crew-01": SIMD2(-0.018, -0.025)
        case "crew-02": SIMD2(0.018, -0.025)
        default: .zero
        }
    }

    static func beaconPosition(markerID: String, surfacePosition: SIMD3<Float>) -> SIMD3<Float> {
        let normal = simd_normalize(surfacePosition)
        var east = simd_cross(SIMD3<Float>(0, 1, 0), normal)
        if simd_length_squared(east) < 0.0001 {
            east = SIMD3<Float>(1, 0, 0)
        } else {
            east = simd_normalize(east)
        }
        let north = simd_normalize(simd_cross(normal, east))
        let offset = tangentOffset(for: markerID)
        let direction = simd_normalize(surfacePosition + east * offset.x + north * offset.y)
        return direction * beaconCenterRadiusMeters
    }

    /// Keep the entire billboard plane in front of the globe, including near its limb.
    static func calloutOffset(markerPosition: SIMD3<Float>, viewerPosition: SIMD3<Float>) -> SIMD3<Float> {
        let view = simd_length_squared(viewerPosition) > 0.0001
            ? simd_normalize(viewerPosition) : SIMD3<Float>(0, 0, 1)
        let clearance = globeRadiusMeters + 0.025 - simd_dot(markerPosition, view)
        return view * max(0.012, clearance)
    }
}

/// Geographic orientation shared by the mesh and its markers.
nonisolated enum GlobeCoordinates {
    static let centerLongitudeDegreesEast: Float = 137.4

    static func normal(latitudeDegrees: Float, longitudeDegreesEast: Float) -> SIMD3<Float> {
        let latitude = latitudeDegrees * .pi / 180
        let longitude = (longitudeDegreesEast - centerLongitudeDegreesEast) * .pi / 180
        return SIMD3(cos(latitude) * sin(longitude), sin(latitude), cos(latitude) * cos(longitude))
    }

    static func normal(textureU: Float, textureV: Float) -> SIMD3<Float> {
        normal(latitudeDegrees: (0.5 - textureV) * 180, longitudeDegreesEast: textureU * 360)
    }
}

nonisolated enum GlobePlacement {
    static func horizontalForward(_ direction: SIMD3<Float>) -> SIMD3<Float> {
        let horizontal = SIMD3<Float>(direction.x, 0, direction.z)
        return simd_length_squared(horizontal) < 0.0001 ? SIMD3(0, 0, -1) : simd_normalize(horizontal)
    }

    static func position(eye: SIMD3<Float>, direction: SIMD3<Float>) -> SIMD3<Float> {
        eye + horizontalForward(direction) * 1.2 + SIMD3<Float>(0, -0.1, 0)
    }
}

nonisolated enum MarsRotation {
    static let solDurationSeconds = 88_775.0
    static let radiansPerSecond = 2 * Double.pi / solDurationSeconds
    // Presentation speed, deliberately faster than Mars's actual rotation.
    static let presentationRadiansPerSecond = 2 * Double.pi / 240

    static func damping(after seconds: Double) -> Double {
        exp(-3 * max(0, seconds))
    }

    static func leveledPitch(_ pitch: Double, after seconds: Double) -> Double {
        pitch * exp(-0.65 * max(0, seconds))
    }
}

nonisolated enum HelmetTerrainPlacement {
    static let eyeHeightMeters: Float = 1.8

    static func translation(for waypointPosition: SIMD3<Float>) -> SIMD3<Float> {
        SIMD3(-waypointPosition.x, -waypointPosition.y - eyeHeightMeters, -waypointPosition.z)
    }
}

nonisolated enum ImmersiveTerrainPlacement {
    static func translation(eye: SIMD3<Float>, terrainPoint: SIMD3<Float>, clearance: Float) -> SIMD3<Float> {
        eye - terrainPoint + SIMD3<Float>(0, -clearance, 0)
    }
}

nonisolated enum AerialOverview {
    static let zoomRange = 0.35...2.5

    static func frame(points: [GridPoint], cellSize: Double, fallback: GridPoint) -> (center: GridPoint, altitude: Double) {
        guard let first = points.first else { return (fallback, 90) }
        let minX = points.map(\.x).min() ?? first.x
        let maxX = points.map(\.x).max() ?? first.x
        let minY = points.map(\.y).min() ?? first.y
        let maxY = points.map(\.y).max() ?? first.y
        let extent = Double(max(maxX - minX, maxY - minY)) * cellSize
        return (GridPoint(x: (minX + maxX) / 2, y: (minY + maxY) / 2), min(1200, max(90, extent * 1.35)))
    }

    static func altitude(_ base: Double, zoom: Double) -> Double {
        min(1200, max(35, base / min(zoomRange.upperBound, max(zoomRange.lowerBound, zoom))))
    }
}

nonisolated enum MissionStage: String, Codable, CaseIterable, Sendable {
    case globe
    case tabletop
    case drone
    case helmet
    case habitat

    var title: String {
        switch self {
        case .globe: "Globe"
        case .tabletop: "Tabletop"
        case .drone: "Bird’s-Eye XR"
        case .helmet: "Helmet POV"
        case .habitat: "ISS Habitat"
        }
    }
}

nonisolated enum MissionAlert: String, Codable, CaseIterable, Identifiable, Sendable {
    case solarParticleEvent
    case slopeSlip
    case swmeCeiling
    case walkBackReserve

    var id: String { rawValue }

    var title: String {
        switch self {
        case .solarParticleEvent: "Solar Particle Event"
        case .slopeSlip: "Slope / Slip Hazard"
        case .swmeCeiling: "SWME Demo Limit"
        case .walkBackReserve: "Walk-Back Reserve"
        }
    }

    var detail: String {
        switch self {
        case .solarParticleEvent: "Demo alert · return to the marked shelter."
        case .slopeSlip: "Demo alert · stop before the marked loose-slope segment."
        case .swmeCeiling: "Demo alert · simulated heat rejection exceeds the planner limit."
        case .walkBackReserve: "Demo alert · simulated reserve is below the chosen threshold."
        }
    }
}

nonisolated struct RadioTransmission: Codable, Hashable, Sendable {
    var id: UUID
    var callsign: String
    var transcript: String
    var endsAt: Date
}

nonisolated struct PlanetCoordinate: Codable, Hashable, Sendable {
    var latitudeDegrees: Double
    var longitudeDegreesEast: Double
}

nonisolated struct MissionLandmark: Identifiable, Hashable, Sendable {
    var id: String
    var name: String
    var detail: String
    var coordinate: PlanetCoordinate?
    var isApproximate: Bool
    var isScenarioOnly: Bool

    static let catalog: [MissionLandmark] = [
        MissionLandmark(
            id: "mount-sharp-boxwork",
            name: "Mount Sharp · Gale Crater",
            detail: "Gale context near the bundled HiRISE crop. This is a regional marker, not a surveyed EVA location.",
            coordinate: PlanetCoordinate(latitudeDegrees: -4.687699920663519, longitudeDegreesEast: 137.3888819769589),
            isApproximate: true,
            isScenarioOnly: false
        ),
        MissionLandmark(
            id: "altadena-boxwork",
            name: "Altadena Boxwork · science stop",
            detail: "Curiosity boxwork science stop. The bundled DTM footprint is Gale context; exact overlap with this stop is unverified.",
            coordinate: PlanetCoordinate(latitudeDegrees: -4.7, longitudeDegreesEast: 137.3),
            isApproximate: true,
            isScenarioOnly: true
        ),
        MissionLandmark(
            id: "jezero-crater",
            name: "Jezero Crater",
            detail: "Perseverance landing site",
            coordinate: PlanetCoordinate(latitudeDegrees: 18.4446, longitudeDegreesEast: 77.4509),
            isApproximate: false,
            isScenarioOnly: false
        ),
        MissionLandmark(
            id: "airlock-alpha",
            name: "Airlock Alpha [DEMO]",
            detail: "Hypothetical mission start and shelter marker; no real habitat is located here.",
            coordinate: PlanetCoordinate(latitudeDegrees: -4.71, longitudeDegreesEast: 137.28),
            isApproximate: true,
            isScenarioOnly: true
        )
    ]
}

nonisolated enum MissionLayer: String, Codable, CaseIterable, Identifiable, Sendable {
    case optical
    case themisInfrared
    case themisNightInfrared
    case globalGeology
    case molaElevation
    case slopeTraction
    case terrainClass
    case radiationShelter
    case thermalShadow
    case radioLineOfSight

    var id: String { rawValue }

    var title: String {
        switch self {
        case .optical: "Visible Optical · Viking"
        case .themisInfrared: "THEMIS Infrared"
        case .themisNightInfrared: "THEMIS Night Infrared"
        case .globalGeology: "USGS Global Geology"
        case .molaElevation: "MOLA Color-Shaded Relief"
        case .slopeTraction: "Slope / Traction"
        case .terrainClass: "Terrain Class"
        case .radiationShelter: "Radiation / Shelter"
        case .thermalShadow: "Thermal Shadow"
        case .radioLineOfSight: "Radio Line of Sight"
        }
    }
}

nonisolated enum SurfaceClass: String, Codable, Sendable {
    case unclassified
    case looseSand
    case cementedRidge
    case scenarioHazard
}

nonisolated struct CrewTelemetry: Identifiable, Codable, Hashable, Sendable {
    var id: String
    var callsign: String
    var point: GridPoint
    var metabolicWatts: Double
    var oxygenPercent: Double
    var coolingWaterKilograms: Double
    var walkBackMarginPercent: Double
    var radiationDoseMicroSieverts: Double
    var radioLineOfSight: Bool
    var terrainClass: SurfaceClass
    var isSynthetic: Bool

    static let demoCrew = [
        CrewTelemetry(
            id: "crew-01",
            callsign: "EVA-01",
            point: GridPoint(x: 18, y: 64),
            metabolicWatts: 330,
            oxygenPercent: 91,
            coolingWaterKilograms: 4.8,
            walkBackMarginPercent: 74,
            radiationDoseMicroSieverts: 8.2,
            radioLineOfSight: true,
            terrainClass: .cementedRidge,
            isSynthetic: true
        ),
        CrewTelemetry(
            id: "crew-02",
            callsign: "EVA-02",
            point: GridPoint(x: 21, y: 67),
            metabolicWatts: 366,
            oxygenPercent: 88,
            coolingWaterKilograms: 4.4,
            walkBackMarginPercent: 69,
            radiationDoseMicroSieverts: 9.1,
            radioLineOfSight: true,
            terrainClass: .unclassified,
            isSynthetic: true
        )
    ]
}

nonisolated struct GridPoint: Codable, Hashable, Sendable, Comparable {
    var x: Int
    var y: Int

    nonisolated static func < (lhs: GridPoint, rhs: GridPoint) -> Bool {
        lhs.y == rhs.y ? lhs.x < rhs.x : lhs.y < rhs.y
    }
}

nonisolated struct RouteWeights: Codable, Hashable, Sendable {
    var metabolic: Double
    var traction: Double
    var thermal: Double
    var radiation: Double
    var communications: Double
}

nonisolated enum RouteWeightPreset: String, Codable, CaseIterable, Identifiable, Sendable {
    case balancedScience
    case suitSafety
    case solarEmergency

    var id: String { rawValue }

    var title: String {
        switch self {
        case .balancedScience: "Balanced Science"
        case .suitSafety: "Suit Safety"
        case .solarEmergency: "Solar Storm"
        }
    }

    var weights: RouteWeights {
        switch self {
        case .balancedScience:
            RouteWeights(metabolic: 0.25, traction: 0.25, thermal: 0.15, radiation: 0.15, communications: 0.20)
        case .suitSafety:
            RouteWeights(metabolic: 0.35, traction: 0.40, thermal: 0.10, radiation: 0.05, communications: 0.10)
        case .solarEmergency:
            RouteWeights(metabolic: 0.20, traction: 0.15, thermal: 0.10, radiation: 0.35, communications: 0.20)
        }
    }
}

nonisolated struct RouteResult: Codable, Hashable, Sendable {
    var path: [GridPoint]
    var distanceMeters: Double
    var traverseMinutes: Double
    var energyKilojoules: Double
    var coolingWaterKilograms: Double
    var doseMicroSieverts: Double
    var minimumSlopeDegrees: Double
    var maximumSlopeDegrees: Double
    var emergencyBrakingDistanceMeters: Double
    var radioLineOfSightFraction: Double
    var walkBackMarginPercent: Double
    var usesScenarioOverlay: Bool
    var safetyViolations: [String]
    var warning: String?

    var isSafe: Bool { safetyViolations.isEmpty }
}

nonisolated enum RouteFailureReason: String, Codable, Hashable, Sendable {
    case blockedEndpoint
    case noPassablePath
    case candidatesRejected

    var message: String {
        switch self {
        case .blockedEndpoint: "An endpoint is on excluded terrain."
        case .noPassablePath: "No passable path found between these points."
        case .candidatesRejected: "Candidate routes exceeded a demo constraint; no demo route found."
        }
    }
}

nonisolated struct RouteComparison: Codable, Hashable, Sendable {
    var origin: GridPoint
    var destination: GridPoint
    var straightLinePath: [GridPoint]
    var straightLineDistanceMeters: Double
    var straightLineResult: RouteResult
    var routed: RouteResult
    var isWalkBack: Bool
    // Missing on older SharePlay snapshots; nil means a routed path was found.
    var failureReason: RouteFailureReason? = nil
}

/// A fictional dust event and its one-way return calculation; not live telemetry.
nonisolated struct EmergencyDemoState: Sendable {
    var crewPoint: GridPoint
    var returnRoute: RouteComparison?
    var limitingResource: String?
    var remainingReservePercent: Double?
}

nonisolated struct MissionStateSnapshot: Codable, Hashable, Sendable {
    var revision: UInt64
    var stage: MissionStage
    var globeRotationOffset: Double
    var selectedLandmarkID: String
    var selectedCrewID: String
    var isCrewCardVisible: Bool
    var isLandmarkCardVisible: Bool
    var activeLayers: Set<MissionLayer>
    var selectedGlobeLayer: MissionLayer
    var markerPositions: [String: GridPoint]
    var playbackSpeed: Double
    var selectedPlaybackProgress: Double
    var inspectionOffset: GridPoint
    var helmetWaypoint: GridPoint
    var weightPreset: RouteWeightPreset
    var solarStormActive: Bool
    var activeAlert: MissionAlert?
    var radioTransmission: RadioTransmission?
    var liveEVAPlayback: Bool
    var playbackStartTime: Date?
    var routeComparison: RouteComparison?
}

nonisolated struct EditableMissionMarker: Identifiable, Codable, Hashable, Sendable {
    var id: String
    var title: String
    var point: GridPoint
    var isSynthetic: Bool
    var kind: MarkerKind

    enum MarkerKind: String, Codable, Sendable {
        case airlock
        case scienceStop
        case crew
        case shelter
        case waypoint
    }
}

nonisolated struct TerrainGrid: Sendable {
    let width: Int
    let height: Int
    let cellSizeMeters: Double
    let elevationsMeters: [Float]
    let sourceProduct: String

    func contains(_ point: GridPoint) -> Bool {
        point.x >= 0 && point.y >= 0 && point.x < width && point.y < height
    }

    func elevation(at point: GridPoint) -> Double {
        guard contains(point) else { return 0 }
        return Double(elevationsMeters[point.y * width + point.x])
    }

    func relativeElevation(at point: GridPoint) -> Double {
        elevation(at: point) - elevation(at: GridPoint(x: width / 2, y: height / 2))
    }
}

nonisolated struct TerrainMetadata: Decodable, Sendable {
    nonisolated struct SourceLocation: Decodable, Sendable {
        var latitudeCenterDegrees: Double
        var longitudeCenterDegreesEast: Double
        var coordinatePrecision: String
    }

    nonisolated struct RegisteredOrthophoto: Decodable, Sendable {
        var sourceProduct: String
        var sourceFile: URL
        var instrument: String
        var mapScaleMetersPerPixel: Double
        var sourceStereoPair: [String]
        var projectionAlignedToDTM: Bool
        var cropOriginPixels: PixelOrigin
        var cropSizePixels: PixelSize
        var displayStretch: String
    }

    nonisolated struct PixelOrigin: Decodable, Sendable {
        var x: Int
        var y: Int
    }

    nonisolated struct PixelSize: Decodable, Sendable {
        var width: Int
        var height: Int
    }

    var sourceProduct: String
    var sourcePage: URL
    var sourceInstitution: String
    var mission: String
    var instrument: String
    var originalPostSpacingMeters: Double
    var gridSpacingMeters: Double
    var gridSize: Int
    var sourceLocation: SourceLocation
    var registeredOrthophoto: RegisteredOrthophoto?
    var verticalDatum: String
    var registrationNote: String
    var processing: String
}
