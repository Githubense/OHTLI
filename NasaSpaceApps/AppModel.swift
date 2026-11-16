import Foundation
import Observation

/// Single local source of truth for the globe, terrain table, immersive scene, and SharePlay.
@MainActor
@Observable
final class MissionStore {
    let immersiveSpaceID = "ImmersiveSpace"
    let missionWindowID = "MissionHub"
    let controlsWindowID = "MissionControls"

    enum ImmersiveSpaceState: Equatable, Sendable {
        case closed
        case inTransition
        case open
    }

    var immersiveSpaceState = ImmersiveSpaceState.closed
    var stage: MissionStage = .globe
    var isPlanningSceneReady = false
    var isImmersiveTerrainReady = false
    var planningSceneError: String?
    var immersiveTerrainError: String?

    /// Each stage depends only on the scene that renders it.
    func isReady(for stage: MissionStage) -> Bool {
        switch stage {
        case .globe: true
        case .tabletop: terrainAsset != nil && isPlanningSceneReady
        case .drone, .helmet: terrainAsset != nil && isImmersiveTerrainReady
        case .habitat: isImmersiveTerrainReady
        }
    }

    var currentTerrainLoadError: String? {
        if let dataLoadMessage { return dataLoadMessage }
        return stage == .drone || stage == .helmet ? immersiveTerrainError : planningSceneError
    }
    var globeRotationOffset = 0.0
    var selectedLandmarkID = "mount-sharp-boxwork"
    var selectedCrewID = "crew-01"
    var isCrewCardVisible = false
    var isLandmarkCardVisible = false
    var isEVADrawerVisible = false
    var activeLayers: Set<MissionLayer> = [.optical]
    var selectedGlobeLayer: MissionLayer = .optical
    var weightPreset = RouteWeightPreset.balancedScience
    var solarStormActive = false
    var activeAlert: MissionAlert?
    private(set) var radioTransmission: RadioTransmission?
    private(set) var remoteRadioTransmission: RadioTransmission?
    var liveEVAPlayback = false
    var playbackStartTime: Date?
    var playbackSpeed = 1.0
    var selectedPlaybackProgress = 0.0
    var markerPositions: [String: GridPoint] = [
        "airlock-alpha": GridPoint(x: 18, y: 64),
        "altadena-boxwork": GridPoint(x: 92, y: 64),
        "crew-01": GridPoint(x: 18, y: 64),
        "crew-02": GridPoint(x: 21, y: 67),
        "shelter-alpha": GridPoint(x: 18, y: 64)
    ]
    var inspectionOffset = GridPoint(x: 0, y: 0)
    var aerialZoom = 1.0
    var helmetWaypoint = GridPoint(x: 18, y: 64)
    var routeComparison: RouteComparison?
    private(set) var emergencyDemo: EmergencyDemoState?
    @ObservationIgnored private var savedEmergencyState: SavedEmergencyState?
    private struct SavedEmergencyState {
        var route: RouteComparison?
        var crewPoint: GridPoint?
        var waypoint: GridPoint
        var playbackEnabled: Bool
        var playbackProgress: Double
        var solarStormActive: Bool
        var alert: MissionAlert?
    }
    var sessionStatus = "Not sharing"
    var selectedImmersiveMode: MissionStage = .drone
    var dataLoadMessage: String?
    var immersionErrorMessage: String?
    private(set) var snapshotRevision: UInt64 = 0
    private(set) var playbackTick: UInt64 = 0

    let landmarks = MissionLandmark.catalog
    let terrainAsset: MarsDataAsset?

    @ObservationIgnored private var snapshotPublisher: ((MissionStateSnapshot) -> Void)?
    @ObservationIgnored private let router = WeightedAStarRouter()
    @ObservationIgnored private var playbackTask: Task<Void, Never>?
    @ObservationIgnored private var radioTransmissionTask: Task<Void, Never>?

    private let playbackDurationSeconds = 45.0

    init() {
        do {
            terrainAsset = try MarsDataCatalog.loadBundled()
            dataLoadMessage = nil
        } catch {
            terrainAsset = nil
            dataLoadMessage = error.localizedDescription
        }
        recalculateRoute(publish: false)
    }

    var selectedLandmark: MissionLandmark {
        landmarks.first(where: { $0.id == selectedLandmarkID }) ?? landmarks[0]
    }

    var hasGaleTerrainContext: Bool {
        selectedLandmarkID == "mount-sharp-boxwork"
            || selectedLandmarkID == "altadena-boxwork"
            || selectedLandmarkID == "airlock-alpha"
    }

    private var routeStart: GridPoint {
        markerPositions["airlock-alpha"] ?? GridPoint(x: 18, y: 64)
    }

    var editableMarkers: [EditableMissionMarker] {
        var result = [
            EditableMissionMarker(id: "airlock-alpha", title: "Airlock Alpha [DEMO]", point: markerPositions["airlock-alpha"] ?? GridPoint(x: 18, y: 64), isSynthetic: true, kind: .airlock),
            EditableMissionMarker(id: "altadena-boxwork", title: "Altadena Boxwork", point: markerPositions["altadena-boxwork"] ?? GridPoint(x: 92, y: 64), isSynthetic: true, kind: .scienceStop),
            EditableMissionMarker(id: "shelter-alpha", title: "Shelter [DEMO]", point: markerPositions["shelter-alpha"] ?? GridPoint(x: 18, y: 64), isSynthetic: true, kind: .shelter)
        ]
        result += CrewTelemetry.demoCrew.map { crew in
            EditableMissionMarker(id: crew.id, title: crew.callsign, point: markerPositions[crew.id] ?? crew.point, isSynthetic: true, kind: .crew)
        }
        return result
    }

    var crewTelemetry: [CrewTelemetry] {
        _ = playbackTick
        var crew = CrewTelemetry.demoCrew
        if liveEVAPlayback, !crew.isEmpty, let start = playbackStartTime,
           let path = routeComparison?.routed.path, !path.isEmpty {
            let progress = min(1, max(0, Date().timeIntervalSince(start) * playbackSpeed / playbackDurationSeconds))
            let index = min(path.count - 1, Int(progress * Double(path.count - 1)))
            crew[0].point = path[index]
            if crew.count > 1 {
                let nextIndex = min(path.count - 1, index + 2)
                crew[1].point = path[nextIndex]
            }
            crew[0].metabolicWatts = 330 + (progress * 70)
            crew[0].walkBackMarginPercent = max(50, 74 - progress * 14)
        }
        for index in crew.indices {
            if let point = markerPositions[crew[index].id], !liveEVAPlayback { crew[index].point = point }
        }
        if let emergencyDemo, !crew.isEmpty {
            crew[0].point = emergencyDemo.crewPoint
            // This is the frozen starting state of the one-way demo budget.
            crew[0].oxygenPercent = router.emergencyStartingFraction * 100
            crew[0].coolingWaterKilograms = router.emergencyStartingFraction * router.constraints.demoCoolingWaterCapacityKilograms
            crew[0].walkBackMarginPercent = emergencyDemo.remainingReservePercent ?? 0
        }
        if solarStormActive {
            for index in crew.indices {
                crew[index].radiationDoseMicroSieverts += 12
                crew[index].radioLineOfSight = index == 0
            }
        }
        return crew
    }

    var playbackProgress: Double {
        _ = playbackTick
        guard liveEVAPlayback, let start = playbackStartTime else { return selectedPlaybackProgress }
        return min(1, max(0, Date().timeIntervalSince(start) * playbackSpeed / playbackDurationSeconds))
    }

    func selectLandmark(_ id: String) {
        guard landmarks.contains(where: { $0.id == id }) else { return }
        selectedLandmarkID = id
        isCrewCardVisible = false
        isLandmarkCardVisible = true
        if hasGaleTerrainContext { recalculateRoute(publish: false) }
        publishSnapshot()
    }

    func selectCrew(_ id: String) {
        guard crewTelemetry.contains(where: { $0.id == id }) else { return }
        selectedCrewID = id
        isLandmarkCardVisible = false
        isCrewCardVisible = true
        publishSnapshot()
    }

    func dismissCrewCard() {
        guard isCrewCardVisible else { return }
        isCrewCardVisible = false
        publishSnapshot()
    }

    func setStage(_ newStage: MissionStage) {
        if newStage == .drone && stage != .drone {
            inspectionOffset = GridPoint(x: 0, y: 0)
            aerialZoom = 1
        }
        stage = newStage
        if newStage == .drone || newStage == .helmet || newStage == .habitat { selectedImmersiveMode = newStage }
        immersionErrorMessage = nil
        publishSnapshot()
    }

    func setGlobeRotationOffset(_ radians: Double) {
        globeRotationOffset = radians.truncatingRemainder(dividingBy: 2 * .pi)
        publishSnapshot()
    }

    func toggleLayer(_ layer: MissionLayer) {
        if layer == .themisInfrared || layer == .themisNightInfrared || layer == .molaElevation || layer == .globalGeology {
            selectGlobeLayer(layer)
            return
        }
        if activeLayers.contains(layer) {
            activeLayers.remove(layer)
        } else {
            activeLayers.insert(layer)
        }
        publishSnapshot()
    }

    func selectGlobeLayer(_ layer: MissionLayer) {
        guard layer == .optical || layer == .themisInfrared || layer == .themisNightInfrared || layer == .molaElevation || layer == .globalGeology else { return }
        selectedGlobeLayer = layer
        activeLayers.formUnion([.optical, .themisInfrared, .molaElevation])
        publishSnapshot()
    }

    func moveMarker(_ id: String, to point: GridPoint) {
        guard emergencyDemo == nil else { return }
        guard let grid = terrainAsset?.terrain, grid.contains(point), markerPositions[id] != nil else { return }
        markerPositions[id] = point
        if id == "crew-01" { helmetWaypoint = point }
        if id == "airlock-alpha" || id == "altadena-boxwork" || id.hasPrefix("crew-") {
            recalculateRoute(publish: false)
        }
        publishSnapshot()
    }

    func resetMarkerPositions() {
        markerPositions = [
            "airlock-alpha": GridPoint(x: 18, y: 64),
            "altadena-boxwork": GridPoint(x: 92, y: 64),
            "crew-01": GridPoint(x: 18, y: 64),
            "crew-02": GridPoint(x: 21, y: 67),
            "shelter-alpha": GridPoint(x: 18, y: 64)
        ]
        helmetWaypoint = GridPoint(x: 18, y: 64)
        recalculateRoute(publish: false)
        publishSnapshot()
    }

    func moveInspection(dx: Int, dy: Int) {
        guard let grid = terrainAsset?.terrain else { return }
        inspectionOffset = GridPoint(
            x: min(grid.width - 1 - helmetWaypoint.x, max(-helmetWaypoint.x, inspectionOffset.x + dx)),
            y: min(grid.height - 1 - helmetWaypoint.y, max(-helmetWaypoint.y, inspectionOffset.y + dy))
        )
        publishSnapshot()
    }

    func zoomAerial(by factor: Double) {
        aerialZoom = min(AerialOverview.zoomRange.upperBound, max(AerialOverview.zoomRange.lowerBound, aerialZoom * factor))
    }

    func moveHelmetWaypoint(dx: Int, dy: Int) {
        guard let grid = terrainAsset?.terrain else { return }
        let next = GridPoint(x: helmetWaypoint.x + dx, y: helmetWaypoint.y + dy)
        guard grid.contains(next) else { return }
        helmetWaypoint = next
        publishSnapshot()
    }

    func setPlaybackSpeed(_ speed: Double) {
        let progress = playbackProgress
        playbackSpeed = [1.0, 5.0, 10.0].first(where: { $0 == speed }) ?? 1.0
        selectedPlaybackProgress = progress
        if liveEVAPlayback {
            playbackStartTime = Date().addingTimeInterval(-progress * playbackDurationSeconds / playbackSpeed)
        }
        publishSnapshot()
    }

    func scrubPlayback(to progress: Double) {
        let bounded = min(1, max(0, progress))
        selectedPlaybackProgress = bounded
        playbackStartTime = Date().addingTimeInterval(-bounded * playbackDurationSeconds / playbackSpeed)
        if liveEVAPlayback { startPlaybackTimer() }
        publishSnapshot()
    }

    func chooseWeights(_ preset: RouteWeightPreset) {
        weightPreset = preset
        recalculateRoute(publish: false)
        publishSnapshot()
    }

    func setPlayback(_ enabled: Bool) {
        let currentProgress = playbackProgress
        if enabled && currentProgress >= 1 { selectedPlaybackProgress = 0 }
        else { selectedPlaybackProgress = currentProgress }
        liveEVAPlayback = enabled
        playbackStartTime = enabled ? Date().addingTimeInterval(-selectedPlaybackProgress * playbackDurationSeconds / playbackSpeed) : nil
        if enabled { startPlaybackTimer() } else { stopPlaybackTimer() }
        publishSnapshot()
    }

    /// Freeze a point on the existing scenario route before calculating a distinct one-way return.
    func startEmergencyDemo() {
        guard emergencyDemo == nil, let grid = terrainAsset?.terrain,
              let existing = routeComparison, existing.failureReason == nil,
              existing.routed.path.count > 1 else { return }
        let path = existing.routed.path
        let crewPoint = path[max(1, min(path.count - 1, path.count / 2))]
        let previousProgress = playbackProgress
        savedEmergencyState = SavedEmergencyState(route: existing, crewPoint: markerPositions["crew-01"],
            waypoint: helmetWaypoint, playbackEnabled: liveEVAPlayback, playbackProgress: previousProgress,
            solarStormActive: solarStormActive, alert: activeAlert)
        liveEVAPlayback = false
        playbackStartTime = nil
        stopPlaybackTimer()
        solarStormActive = false
        activeAlert = nil
        markerPositions["crew-01"] = crewPoint
        helmetWaypoint = crewPoint
        let returnRoute = router.emergencyReturn(on: grid, from: crewPoint, to: routeStart,
                                                 weights: RouteWeightPreset.suitSafety.weights)
        let result = returnRoute?.failureReason == nil ? returnRoute?.routed : nil
        emergencyDemo = EmergencyDemoState(crewPoint: crewPoint, returnRoute: returnRoute,
            limitingResource: result.map { router.emergencyLimitingResource(for: $0) },
            remainingReservePercent: result?.walkBackMarginPercent)
        routeComparison = returnRoute
        publishSnapshot()
    }

    func resetEmergencyDemo() {
        guard let saved = savedEmergencyState else { return }
        emergencyDemo = nil
        savedEmergencyState = nil
        routeComparison = saved.route
        if let point = saved.crewPoint { markerPositions["crew-01"] = point }
        helmetWaypoint = saved.waypoint
        solarStormActive = saved.solarStormActive
        activeAlert = saved.alert
        selectedPlaybackProgress = saved.playbackProgress
        liveEVAPlayback = saved.playbackEnabled
        if saved.playbackEnabled {
            playbackStartTime = Date().addingTimeInterval(-saved.playbackProgress * playbackDurationSeconds / playbackSpeed)
            startPlaybackTimer()
        } else {
            playbackStartTime = nil
            stopPlaybackTimer()
        }
        publishSnapshot()
    }

    func setSolarStormActive(_ active: Bool) {
        solarStormActive = active
        activeAlert = active ? .solarParticleEvent : nil
        if active {
            liveEVAPlayback = true
            if playbackStartTime == nil { playbackStartTime = Date().addingTimeInterval(-playbackDurationSeconds * 0.45 / playbackSpeed) }
            startPlaybackTimer()
        } else {
            liveEVAPlayback = false
            playbackStartTime = nil
            stopPlaybackTimer()
        }
        recalculateRoute(publish: false)
        publishSnapshot()
    }

    func triggerDemoAlert(_ alert: MissionAlert) {
        if alert == .solarParticleEvent {
            setSolarStormActive(true)
            return
        }
        if solarStormActive { setSolarStormActive(false) }
        solarStormActive = false
        activeAlert = alert
        publishSnapshot()
    }

    func clearSafetyAlert() {
        if solarStormActive {
            setSolarStormActive(false)
        } else if activeAlert != nil {
            activeAlert = nil
            publishSnapshot()
        }
    }

    func beginDemoRadioTransmission(for telemetry: CrewTelemetry) {
        let transmission = RadioTransmission(
            id: UUID(),
            callsign: telemetry.callsign,
            transcript: "Waypoint check. Route is nominal.",
            endsAt: Date().addingTimeInterval(1.6)
        )
        radioTransmission = transmission
        publishSnapshot()
        radioTransmissionTask?.cancel()
        radioTransmissionTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(3.6))
            guard !Task.isCancelled, self?.radioTransmission?.id == transmission.id else { return }
            self?.radioTransmission = nil
            self?.publishSnapshot()
            self?.radioTransmissionTask = nil
        }
    }

    var remoteRadioOpacity: Double {
        guard activeAlert == nil, let transmission = remoteRadioTransmission else { return 0 }
        let afterEnd = Date().timeIntervalSince(transmission.endsAt)
        return afterEnd <= 0 ? 1 : max(0, 1 - afterEnd / 2)
    }

    func recalculateRoute(publish: Bool = true) {
        guard emergencyDemo == nil else { return }
        guard let terrainAsset, hasGaleTerrainContext else {
            routeComparison = nil
            if publish { publishSnapshot() }
            return
        }

        let origin = solarStormActive ? currentCrewPoint : (markerPositions["airlock-alpha"] ?? GridPoint(x: 18, y: 64))
        let destination = solarStormActive ? (markerPositions["shelter-alpha"] ?? GridPoint(x: 18, y: 64)) : (markerPositions["altadena-boxwork"] ?? GridPoint(x: 92, y: 64))
        if origin == destination {
            routeComparison = nil
            if publish { publishSnapshot() }
            return
        }

        routeComparison = router.compare(
            on: terrainAsset.terrain,
            from: origin,
            to: destination,
            weights: weightPreset.weights,
            solarStormActive: solarStormActive
        )
        if publish { publishSnapshot() }
    }

    func bindSnapshotPublisher(_ publisher: @escaping (MissionStateSnapshot) -> Void) {
        snapshotPublisher = publisher
    }

    func applyRemoteSnapshot(_ snapshot: MissionStateSnapshot) {
        snapshotRevision = max(snapshotRevision, snapshot.revision)
        stage = snapshot.stage
        globeRotationOffset = snapshot.globeRotationOffset
        selectedLandmarkID = snapshot.selectedLandmarkID
        selectedCrewID = snapshot.selectedCrewID
        isCrewCardVisible = snapshot.isCrewCardVisible
        isLandmarkCardVisible = snapshot.isLandmarkCardVisible
        activeLayers = snapshot.activeLayers
        selectedGlobeLayer = snapshot.selectedGlobeLayer
        markerPositions = snapshot.markerPositions
        playbackSpeed = snapshot.playbackSpeed
        selectedPlaybackProgress = snapshot.selectedPlaybackProgress
        inspectionOffset = snapshot.inspectionOffset
        helmetWaypoint = snapshot.helmetWaypoint
        weightPreset = snapshot.weightPreset
        solarStormActive = snapshot.solarStormActive
        activeAlert = snapshot.activeAlert
        remoteRadioTransmission = snapshot.radioTransmission
        liveEVAPlayback = snapshot.liveEVAPlayback
        playbackStartTime = snapshot.playbackStartTime
        routeComparison = snapshot.routeComparison
        if liveEVAPlayback { startPlaybackTimer() } else { stopPlaybackTimer() }
    }

    func currentSnapshot() -> MissionStateSnapshot {
        MissionStateSnapshot(
            revision: snapshotRevision,
            stage: stage,
            globeRotationOffset: globeRotationOffset,
            selectedLandmarkID: selectedLandmarkID,
            selectedCrewID: selectedCrewID,
            isCrewCardVisible: isCrewCardVisible,
            isLandmarkCardVisible: isLandmarkCardVisible,
            activeLayers: activeLayers,
            selectedGlobeLayer: selectedGlobeLayer,
            markerPositions: markerPositions,
            playbackSpeed: playbackSpeed,
            selectedPlaybackProgress: playbackProgress,
            inspectionOffset: inspectionOffset,
            helmetWaypoint: helmetWaypoint,
            weightPreset: weightPreset,
            solarStormActive: solarStormActive,
            activeAlert: activeAlert,
            radioTransmission: radioTransmission,
            liveEVAPlayback: liveEVAPlayback,
            playbackStartTime: playbackStartTime,
            routeComparison: routeComparison
        )
    }

    private var currentCrewPoint: GridPoint {
        _ = playbackTick
        guard liveEVAPlayback, let start = playbackStartTime,
              let path = routeComparison?.routed.path, !path.isEmpty else { return routeStart }
        let progress = min(1, max(0, Date().timeIntervalSince(start) * playbackSpeed / playbackDurationSeconds))
        return path[min(path.count - 1, Int(progress * Double(path.count - 1)))]
    }

    private func publishSnapshot() {
        snapshotRevision &+= 1
        snapshotPublisher?(currentSnapshot())
    }

    private func startPlaybackTimer() {
        playbackTask?.cancel()
        playbackTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while !Task.isCancelled, self.liveEVAPlayback {
                try? await Task.sleep(for: .milliseconds(67))
                guard !Task.isCancelled else { break }
                self.playbackTick &+= 1
                if self.playbackProgress >= 1 {
                    self.liveEVAPlayback = false
                    self.playbackStartTime = nil
                    self.selectedPlaybackProgress = 1
                    self.playbackTask = nil
                    self.publishSnapshot()
                    break
                }
            }
        }
    }

    private func stopPlaybackTimer() {
        playbackTask?.cancel()
        playbackTask = nil
        playbackTick &+= 1
    }
}
