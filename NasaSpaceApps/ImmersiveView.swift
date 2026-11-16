import RealityKit
import ARKit
import QuartzCore
import GroupActivities
import SwiftUI
import UIKit

struct ImmersiveView: View {
    var isPlanningVolume = false
    @Environment(MissionStore.self) private var missionStore
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @Binding var immersionStyle: any ImmersionStyle

    @State private var sceneGraph = ImmersiveSceneGraph()
    @State private var framePulse = 0
    @State private var globeRotation: CGFloat = 0
    @State private var globePitch: CGFloat = 0
    @State private var globeVelocity = CGSize.zero
    @State private var lastGlobeInteraction = Date.distantPast
    @GestureState private var dragRotation = CGSize.zero
    @GestureState private var globeIsDragging = false
    @State private var lastFrameTime = Date()

    var body: some View {
        GeometryReader3D { geometry in
        RealityView { content, attachments in
            await buildScene(in: content, attachments: attachments)
        } update: { content, attachments in
            _ = framePulse
            if isPlanningVolume {
                fitTable(in: content.convert(geometry.frame(in: .local), from: .local, to: .scene))
            }
            updateScene(attachments: attachments)
        } attachments: {
            ForEach(missionStore.landmarks) { landmark in
                Attachment(id: "globe-label:\(landmark.id)") {
                    GlobeLandmarkButton(landmark: landmark) {
                        missionStore.selectLandmark(landmark.id)
                    }
                }
            }
            Attachment(id: "crew-info-card") {
                if let telemetry = selectedCrewTelemetry {
                    CrewInfoCard(telemetry: telemetry, emergency: telemetry.id == "crew-01" ? missionStore.emergencyDemo : nil, transmit: {
                        missionStore.beginDemoRadioTransmission(for: telemetry)
                    }) {
                        missionStore.dismissCrewCard()
                    }
                }
            }
            if let transmission = missionStore.remoteRadioTransmission,
               missionStore.remoteRadioOpacity > 0 {
                Attachment(id: "radio-comms-pill") {
                    RadioCommsPill(transmission: transmission, opacity: missionStore.remoteRadioOpacity)
                }
            }
            if missionStore.isEVADrawerVisible {
                Attachment(id: "eva-drawer") {
                    ActiveEVADrawer(missionStore: missionStore)
                }
            }
            Attachment(id: "landmark-info-card") {
                LandmarkInfoCard(landmark: missionStore.selectedLandmark, isTerrainReady: missionStore.isReady(for: .tabletop), terrainUnavailable: missionStore.dataLoadMessage != nil || missionStore.planningSceneError != nil) {
                    missionStore.isLandmarkCardVisible = false
                } explore: {
                    missionStore.isLandmarkCardVisible = false
                    missionStore.setStage(.tabletop)
                }
            }
            Attachment(id: "helmet-hud") {
                HelmetVisorHUD(missionStore: missionStore)
            }
            Attachment(id: "emergency-alert") {
                if let alert = missionStore.activeAlert {
                    EmergencyAlertCard(alert: alert)
                }
            }
            if let asset = missionStore.terrainAsset {
                let routeGrid = asset.terrain
                let grid = asset.detailedTerrain ?? routeGrid
                let mapMarkers = missionStore.editableMarkers
                    .filter { $0.kind == .airlock || $0.kind == .scienceStop }
                    .map { marker -> EditableMissionMarker in
                        var displayMarker = marker
                        displayMarker.point = resample(marker.point, from: routeGrid, to: grid)
                        return displayMarker
                    }
                Attachment(id: "map-layer-overlay") {
                    TerrainCanvas(
                        grid: grid,
                        comparison: missionStore.routeComparison,
                        routeGrid: routeGrid,
                        showSlope: false,
                        showHazards: false,
                        showRadiation: false,
                        showThermal: false,
                        showRadio: false,
                        showsRoutes: false,
                        editableMarkers: mapMarkers,
                        onMarkerMoved: { id, point in missionStore.moveMarker(id, to: resample(point, from: grid, to: routeGrid)) },
                        onMapTap: { point in missionStore.moveMarker("altadena-boxwork", to: resample(point, from: grid, to: routeGrid)) }
                    )
                    .frame(width: 480, height: 480)
                    .clipShape(Circle())
                }
            }
            if let grid = missionStore.terrainAsset?.terrain {
                Attachment(id: "habitat-map-overlay") {
                    TerrainCanvas(
                        grid: grid,
                        comparison: missionStore.routeComparison,
                        showSlope: missionStore.activeLayers.contains(.slopeTraction),
                        showHazards: missionStore.activeLayers.contains(.terrainClass),
                        showRadiation: missionStore.activeLayers.contains(.radiationShelter),
                        showThermal: missionStore.activeLayers.contains(.thermalShadow),
                        showRadio: missionStore.activeLayers.contains(.radioLineOfSight),
                        showsRoutes: true,
                        editableMarkers: missionStore.editableMarkers,
                        onMarkerMoved: { id, point in missionStore.moveMarker(id, to: point) }
                    )
                    .frame(width: 420, height: 420)
                    .clipShape(Circle())
                }
            }
        }
        }
        .simultaneousGesture(spatialTapGesture)
        // Keep globe dragging simultaneous with SwiftUI attachment controls and
        // TerrainCanvas gestures. A parent-exclusive drag can capture taps that
        // should activate the world-anchored dock or map attachments.
        .simultaneousGesture(
            DragGesture(minimumDistance: 8)
                .targetedToAnyEntity()
                .updating($dragRotation) { value, state, _ in
                    state = value.entity.name == "mars-globe" && missionStore.stage == .globe
                        ? CGSize(width: value.translation.width / 220, height: value.translation.height / 220)
                        : .zero
                }
                .updating($globeIsDragging) { value, state, _ in
                    state = value.entity.name == "mars-globe" && missionStore.stage == .globe
                }
                .onChanged { value in
                    guard value.entity.name == "mars-globe", missionStore.stage == .globe else { return }
                    globeVelocity = .zero
                    lastGlobeInteraction = Date()
                }
                .onEnded { value in
                    guard value.entity.name == "mars-globe", missionStore.stage == .globe else { return }
                    globeRotation += value.translation.width / 220
                    globePitch = max(-1.4, min(1.4, globePitch + value.translation.height / 220))
                    // SwiftUI's predicted end is an estimate of the continuing drag.
                    let predicted = value.predictedEndTranslation
                    globeVelocity = CGSize(
                        width: max(-3, min(3, (predicted.width - value.translation.width) / 55)),
                        height: max(-3, min(3, (predicted.height - value.translation.height) / 55))
                    )
                    lastGlobeInteraction = Date()
                    missionStore.setGlobeRotationOffset(Double(globeRotation))
                }
        )
        .task(id: missionStore.liveEVAPlayback) {
            guard missionStore.liveEVAPlayback else { return }
            while !Task.isCancelled && missionStore.liveEVAPlayback {
                try? await Task.sleep(for: .milliseconds(67))
                guard !Task.isCancelled else { return }
                framePulse &+= 1
            }
        }
        .task {
            lastFrameTime = Date()
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(33))
                guard !Task.isCancelled else { return }
                let now = Date()
                let delta = now.timeIntervalSince(lastFrameTime)
                lastFrameTime = now
                if missionStore.stage == .globe {
                    if !globeIsDragging {
                        let step = CGFloat(min(delta, 0.1))
                        globeRotation += globeVelocity.width * step
                        globePitch = max(-1.4, min(1.4, globePitch + globeVelocity.height * step))
                        let damping = CGFloat(MarsRotation.damping(after: Double(step)))
                        globeVelocity.width *= damping
                        globeVelocity.height *= damping
                        if abs(globeVelocity.width) + abs(globeVelocity.height) < 0.002 {
                            globeVelocity = .zero
                            if now.timeIntervalSince(lastGlobeInteraction) > 2.5 && !missionStore.isLandmarkCardVisible {
                                globePitch = CGFloat(MarsRotation.leveledPitch(Double(globePitch), after: Double(step)))
                                globeRotation += step * CGFloat(MarsRotation.presentationRadiansPerSecond)
                            }
                        }
                    }
                    framePulse &+= 1
                }
            }
        }
        .task {
            if !isPlanningVolume { await trackViewerAndPlaceGlobe() }
        }
        #if DEBUG
        .task {
            guard !isPlanningVolume else { return }
            if let raw = ProcessInfo.processInfo.environment["MARS_SMOKE_STAGE"],
               let stage = MissionStage(rawValue: raw) {
                await Task.yield()
                missionStore.setStage(stage)
            }
            if let raw = ProcessInfo.processInfo.environment["MARS_SMOKE_LAYER"],
               let layer = MissionLayer(rawValue: raw) {
                missionStore.selectGlobeLayer(layer)
            }
            if ProcessInfo.processInfo.environment["MARS_SMOKE_SLOPE"] == "1",
               !missionStore.activeLayers.contains(.slopeTraction) {
                missionStore.toggleLayer(.slopeTraction)
            }
            if let raw = ProcessInfo.processInfo.environment["MARS_SMOKE_STAGE_AFTER_READY"],
               let stage = MissionStage(rawValue: raw) {
                while !missionStore.isReady(for: stage) && !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(200))
                }
                guard !Task.isCancelled else { return }
                missionStore.setStage(stage)
            }
            if ProcessInfo.processInfo.environment["MARS_SMOKE_EMERGENCY"] == "1" {
                while !missionStore.isReady(for: .tabletop) && !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(200))
                }
                guard !Task.isCancelled else { return }
                missionStore.startEmergencyDemo()
            }
            if let landmark = ProcessInfo.processInfo.environment["MARS_SMOKE_LANDMARK"] {
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else { return }
                missionStore.selectLandmark(landmark)
            }
            if ProcessInfo.processInfo.environment["MARS_SMOKE_SEQUENCE"] == "1" {
                for stage in [MissionStage.tabletop, .drone, .helmet, .globe, .drone, .tabletop, .globe] {
                    while !missionStore.isReady(for: stage) && !Task.isCancelled {
                        try? await Task.sleep(for: .milliseconds(200))
                    }
                    guard !Task.isCancelled else { return }
                    missionStore.setStage(stage)
                    let delay = ProcessInfo.processInfo.environment["MARS_SMOKE_RAPID"] == "1" ? 120 : 850
                    try? await Task.sleep(for: .milliseconds(delay))
                }
            }
        }
        #endif
        .task(id: missionStore.stage) {
            guard !isPlanningVolume else { return }
            immersionStyle = missionStore.stage == .globe || missionStore.stage == .tabletop ? .mixed : .full
            if missionStore.stage == .habitat {
                await buildHabitatIfNeeded()
            }
        }
        .onChange(of: missionStore.stage) { _, stage in
            framePulse &+= 1
            if !isPlanningVolume { immersionStyle = stage == .globe || stage == .tabletop ? .mixed : .full }
        }
        .onChange(of: missionStore.selectedCrewID) { _, _ in framePulse &+= 1 }
        .onChange(of: missionStore.isCrewCardVisible) { _, _ in framePulse &+= 1 }
        .onChange(of: missionStore.activeLayers) { _, _ in framePulse &+= 1 }
        .onChange(of: missionStore.routeComparison) { _, _ in framePulse &+= 1 }
        .onChange(of: missionStore.globeRotationOffset) { _, value in globeRotation = CGFloat(value) }
        .onChange(of: missionStore.isLandmarkCardVisible) { _, _ in framePulse &+= 1 }
        .onChange(of: missionStore.markerPositions) { _, _ in framePulse &+= 1 }
        .onChange(of: missionStore.aerialZoom) { _, _ in framePulse &+= 1 }
        .onAppear {
            guard !isPlanningVolume else { return }
            missionStore.immersiveSpaceState = .open
            openWindow(id: missionStore.controlsWindowID, value: "mission-controls")
        }
        .onDisappear {
            sceneGraph.transitionTask?.cancel()
            sceneGraph.nativeDetailTask?.cancel()
            sceneGraph.terrainBuildTask?.cancel()
            if isPlanningVolume {
                missionStore.isPlanningSceneReady = false
                return
            }
            missionStore.isImmersiveTerrainReady = false
            missionStore.immersiveSpaceState = .closed
            dismissWindow(id: missionStore.controlsWindowID)
            // The system can close an immersive space independently of our
            // controls. Keep a way back into the mission in that case.
            openWindow(id: missionStore.missionWindowID)
        }
        .accessibilityLabel("Mars mission space: anchored globe and map, with full immersive drone and habitat views")
    }

    private var selectedCrewTelemetry: CrewTelemetry? {
        missionStore.crewTelemetry.first(where: { $0.id == missionStore.selectedCrewID })
    }

    private var spatialTapGesture: some Gesture {
        SpatialTapGesture()
            .targetedToAnyEntity()
            .onEnded { value in
                handleTap(on: value.entity, at: value.location3D)
            }
    }

    @MainActor
    private func buildScene(in content: RealityViewContent, attachments: RealityViewAttachments) async {
        if !sceneGraph.hasStartedBuildingScene {
            sceneGraph.hasStartedBuildingScene = true
            if isPlanningVolume { await buildGlobe() }
            else { await loadMarsSky() }
        }

        content.add(sceneGraph.controlsAnchor)
        sceneGraph.controlsAnchor.addChild(sceneGraph.alertAudioEntity)
        if isPlanningVolume {
            content.add(sceneGraph.globeRoot)
            content.add(sceneGraph.tableRoot)
            sceneGraph.globeRoot.position = SIMD3<Float>(0, 0.10, 0)
            sceneGraph.tableRoot.position = SIMD3<Float>(0, -0.24, 0.13)
            sceneGraph.tableRoot.orientation = simd_quatf(angle: 0, axis: SIMD3<Float>(1, 0, 0))
            sceneGraph.viewerPosition = SIMD3<Float>(0, 0.10, 1.2)
        } else {
            content.add(sceneGraph.droneAnchor)
            sceneGraph.droneAnchor.addChild(sceneGraph.droneRoot)
            sceneGraph.droneAnchor.addChild(sceneGraph.droneSkyRoot)
            content.add(sceneGraph.habitatAnchor)
            sceneGraph.habitatAnchor.addChild(sceneGraph.habitatRoot)
            content.add(sceneGraph.helmetAnchor)
            sceneGraph.helmetAnchor.addChild(sceneGraph.helmetRoot)
            sceneGraph.helmetAnchor.addChild(sceneGraph.helmetSkyRoot)
        }

        if let alert = attachments.entity(for: "emergency-alert") {
            alert.components.set(BillboardComponent())
            alert.scale = attachmentScale(alert, targetWidth: 0.72)
            alert.position = SIMD3<Float>(0, 0.39, -0.88)
            sceneGraph.dockRoot.addChild(alert)
            sceneGraph.alertEntity = alert
        }
        if let layerOverlay = attachments.entity(for: "map-layer-overlay") {
            layerOverlay.scale = attachmentScale(layerOverlay, targetWidth: 0.88)
            layerOverlay.orientation = simd_quatf(angle: -.pi / 2, axis: SIMD3<Float>(1, 0, 0))
            layerOverlay.position = SIMD3<Float>(0, 0.032, 0)
            sceneGraph.tableRoot.addChild(layerOverlay)
            sceneGraph.layerOverlayEntity = layerOverlay
        }
        if let habitatMapOverlay = attachments.entity(for: "habitat-map-overlay") {
            habitatMapOverlay.scale = attachmentScale(habitatMapOverlay, targetWidth: 0.72)
            habitatMapOverlay.orientation = simd_quatf(angle: -.pi / 2, axis: SIMD3<Float>(1, 0, 0))
            habitatMapOverlay.position = SIMD3<Float>(0, -0.495, -0.95)
            sceneGraph.habitatRoot.addChild(habitatMapOverlay)
            sceneGraph.habitatMapOverlayEntity = habitatMapOverlay
        }

        sceneGraph.globeRoot.isEnabled = missionStore.stage == .globe
        sceneGraph.tableRoot.isEnabled = missionStore.stage == .tabletop
        sceneGraph.droneRoot.isEnabled = missionStore.stage == .drone
        sceneGraph.habitatRoot.isEnabled = missionStore.stage == .habitat
        sceneGraph.helmetRoot.isEnabled = missionStore.stage == .helmet
        sceneGraph.droneSkyRoot.isEnabled = missionStore.stage == .drone
        sceneGraph.helmetSkyRoot.isEnabled = missionStore.stage == .helmet
        // A stage can be selected while the asynchronous scene is loading.
        // Reset any in-flight pre-attachment fade and place the chosen world
        // before revealing it, so its initial frame cannot remain transparent.
        sceneGraph.transitionTask?.cancel()
        for stage in MissionStage.allCases {
            root(for: stage)?.components.set(OpacityComponent(opacity: 1))
        }
        sceneGraph.droneSkyRoot.components.set(OpacityComponent(opacity: 1))
        sceneGraph.helmetSkyRoot.components.set(OpacityComponent(opacity: 1))
        sceneGraph.stageEntryEye = sceneGraph.viewerPosition
        sceneGraph.stageEntryForward = sceneGraph.viewerForward
        sceneGraph.droneSkyRoot.position = sceneGraph.stageEntryEye
        sceneGraph.helmetSkyRoot.position = sceneGraph.stageEntryEye
        sceneGraph.lastInspectionOffset = nil
        sceneGraph.lastHelmetWaypoint = nil
        sceneGraph.renderedStage = missionStore.stage
        sceneGraph.lastRenderedRoute = missionStore.routeComparison
        updateCrewCard(attachments: attachments)
        updateLandmarkCard(attachments: attachments)
        updateHelmetHUD(attachments: attachments)
        updateEVADrawer(attachments: attachments)
        updateCrewPositions()
        updateInspectionPosition()
        updateHelmetPosition()
        #if DEBUG
        NSLog("Mars globe scene attached, stage=%@", missionStore.stage.rawValue)
        #endif
        if sceneGraph.terrainBuildTask == nil {
            sceneGraph.terrainBuildTask = Task { @MainActor in
                await Task.yield()
                await loadGaleSurfaceMaterial()
                guard !Task.isCancelled else { return }
                if isPlanningVolume {
                    await buildTable()
                    updateDroneRoute()
                }
                else { await buildDrone() }
                guard !Task.isCancelled else { return }
                if isPlanningVolume {
                    missionStore.isPlanningSceneReady = sceneGraph.tableTerrainEntity != nil
                    missionStore.planningSceneError = sceneGraph.tableTerrainEntity == nil ? "Gale map could not be loaded. Reopen the mission to retry." : nil
                } else {
                    missionStore.isImmersiveTerrainReady = sceneGraph.droneTerrainEntity != nil && sceneGraph.helmetTerrainEntity != nil
                    missionStore.immersiveTerrainError = missionStore.isImmersiveTerrainReady ? nil : "Immersive terrain could not be loaded. Reopen the mission to retry."
                }
                sceneGraph.renderedStage = nil
                framePulse &+= 1
                #if DEBUG
                NSLog("Mars terrain ready stage=%@ droneChildren=%ld skyChildren=%ld", missionStore.stage.rawValue, sceneGraph.droneRoot.children.count, sceneGraph.droneSkyRoot.children.count)
                #endif
            }
        }
    }

    /// Freeze the globe's placement from the first tracked pose. Continue to sample
    /// the wearer position solely for correct near/far marker visibility.
    @MainActor
    private func trackViewerAndPlaceGlobe() async {
        guard WorldTrackingProvider.isSupported else { return }
        do {
            try await sceneGraph.trackingSession.run([sceneGraph.worldTracking])
        } catch {
            NSLog("World tracking unavailable; using fallback globe position: %@", String(describing: error))
            return
        }
        defer { sceneGraph.trackingSession.stop() }
        while !Task.isCancelled {
            if let anchor = sceneGraph.worldTracking.queryDeviceAnchor(atTimestamp: CACurrentMediaTime()), anchor.isTracked {
                let transform = anchor.originFromAnchorTransform
                let eye = SIMD3<Float>(transform.columns.3.x, transform.columns.3.y, transform.columns.3.z)
                sceneGraph.viewerPosition = eye
                let direction = SIMD3<Float>(-transform.columns.2.x, -transform.columns.2.y, -transform.columns.2.z)
                sceneGraph.viewerForward = GlobePlacement.horizontalForward(direction)
                if !sceneGraph.hasTrackedViewer {
                    sceneGraph.hasTrackedViewer = true
                    if missionStore.stage == .drone || missionStore.stage == .helmet {
                        sceneGraph.stageEntryEye = eye
                        sceneGraph.stageEntryForward = sceneGraph.viewerForward
                        sceneGraph.droneSkyRoot.position = eye
                        sceneGraph.helmetSkyRoot.position = eye
                        sceneGraph.lastInspectionOffset = nil
                        sceneGraph.lastHelmetWaypoint = nil
                        framePulse &+= 1
                    }
                }
                if !sceneGraph.globePlaced {
                    let forward = GlobePlacement.horizontalForward(direction)
                    sceneGraph.globeAnchor.position = GlobePlacement.position(eye: eye, direction: direction)
                    sceneGraph.globeAnchor.orientation = simd_quatf(from: SIMD3<Float>(0, 0, -1), to: forward)
                    sceneGraph.globePlaced = true
                }
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    /// Equirectangular source: 0...360° east left-to-right, north at the top.
    private func makeRegisteredGlobeMesh() -> MeshResource {
        let columns = 320, rows = 160
        let radius = GlobePinLayout.globeRadiusMeters
        var positions: [SIMD3<Float>] = []
        var normals: [SIMD3<Float>] = []
        var texcoords: [SIMD2<Float>] = []
        var indices: [UInt32] = []
        for row in 0...rows {
            let v = Float(row) / Float(rows)
            for column in 0...columns {
                let u = Float(column) / Float(columns)
                let normal = GlobeCoordinates.normal(textureU: u, textureV: v)
                positions.append(normal * radius)
                normals.append(normal)
                texcoords.append(SIMD2<Float>(u, v))
            }
        }
        for row in 0..<rows {
            for column in 0..<columns {
                let a = UInt32(row * (columns + 1) + column)
                let b = a + UInt32(columns + 1)
                indices.append(contentsOf: [a, b, a + 1, a + 1, b, b + 1])
            }
        }
        var descriptor = MeshDescriptor(name: "geographically-registered-mars")
        descriptor.positions = MeshBuffers.Positions(positions)
        descriptor.normals = MeshBuffers.Normals(normals)
        descriptor.textureCoordinates = MeshBuffers.TextureCoordinates(texcoords)
        descriptor.primitives = .triangles(indices)
        return (try? MeshResource.generate(from: [descriptor])) ?? .generateSphere(radius: radius)
    }

    @MainActor
    private func loadMarsSky() async {
        sceneGraph.marsSkyAssets = await MarsTextureLoader.loadSky(named: "MarsSky")
        if let skyAssets = sceneGraph.marsSkyAssets {
            var sky = UnlitMaterial(color: .white)
            var skyColor = sky.color
            skyColor.texture = .init(skyAssets.texture)
            sky.color = skyColor
            sceneGraph.skyMaterial = sky
        }
    }

    @MainActor
    private func buildGlobe() async {
        await loadMarsSky()

        // Keep globe lighting inside its visibility root so it cannot illuminate the other modes.
        sceneGraph.globeSunLight = addDirectionalSun(to: sceneGraph.globeRoot, intensity: 10_000, shadowDistance: 1.8)
        let globeImageLight = addMartianImageLight(to: sceneGraph.globeRoot)
        for layer in [MissionLayer.optical, .themisInfrared, .themisNightInfrared, .molaElevation, .globalGeology] {
            let assetName: String = switch layer {
            case .optical: "MarsViking"
            case .themisInfrared: "MarsTHEMIS"
            case .themisNightInfrared: "MarsTHEMISNight"
            case .globalGeology: "MarsGeology"
            case .molaElevation: "MarsMola"
            default: "MarsViking"
            }
            guard let texture = await MarsTextureLoader.loadAsset(named: assetName) else { continue }
            var material = PhysicallyBasedMaterial()
            material.baseColor = .init(tint: .white, texture: .init(texture))
            material.roughness = 0.92
            material.metallic = 0.0
            sceneGraph.globeMaterials[layer] = material
        }
        let initialMaterial = sceneGraph.globeMaterials[.optical]
            ?? terrainMaterial(color: UIColor(red: 0.58, green: 0.27, blue: 0.17, alpha: 1), roughness: 0.96)
        let mars = ModelEntity(mesh: makeRegisteredGlobeMesh(), materials: [initialMaterial])
        mars.name = "mars-globe"
        mars.components.set(InputTargetComponent())
        mars.components.set(CollisionComponent(shapes: [.generateSphere(radius: GlobePinLayout.globeRadiusMeters)]))
        addImageLightReceiver(to: mars, from: globeImageLight)
        sceneGraph.globeModel = mars
        sceneGraph.globeRoot.addChild(mars)

        var atmosphereMaterial = UnlitMaterial(color: UIColor(red: 1, green: 0.38, blue: 0.20, alpha: 1))
        atmosphereMaterial.blending = .transparent(opacity: 0.035)
        let atmosphere = ModelEntity(
            mesh: .generateSphere(radius: GlobePinLayout.globeRadiusMeters + 0.008),
            materials: [atmosphereMaterial]
        )
        atmosphere.name = "thin-dusty-martian-atmosphere"
        sceneGraph.globeRoot.addChild(atmosphere)

        for landmark in missionStore.landmarks {
            guard let coordinate = landmark.coordinate else { continue }
            let color: UIColor = landmark.id == "jezero-crater" ? .systemTeal : (landmark.isScenarioOnly ? .systemOrange : .systemYellow)
            let marker = makeGlobeBeacon(
                name: "landmark:\(landmark.id)",
                color: color,
                radius: 0.009,
                markerID: landmark.id,
                surfacePosition: globePosition(for: coordinate, radius: GlobePinLayout.globeRadiusMeters)
            )
            sceneGraph.globeLandmarkMarkers[landmark.id] = marker
            sceneGraph.globeRoot.addChild(marker)
        }

        for crew in missionStore.crewTelemetry {
            let surface = globePosition(for: approximateCoordinate(for: crew.point), radius: GlobePinLayout.globeRadiusMeters)
            let marker = makeGlobeBeacon(name: crew.id, color: .systemCyan, radius: 0.009,
                                         markerID: crew.id, surfacePosition: surface)
            sceneGraph.globeCrewMarkers[crew.id] = marker
            sceneGraph.globeRoot.addChild(marker)
        }

        sceneGraph.globeRoot.orientation = simd_quatf(angle: Float(globeRotation), axis: SIMD3<Float>(0, 1, 0))
    }

    @MainActor
    private func loadGaleSurfaceMaterial() async {
        guard let texture = await MarsTextureLoader.loadAsset(named: "GaleHiRISEOrtho") else { return }
        var mapMaterial = UnlitMaterial()
        var mapColor = mapMaterial.color
        mapColor.texture = .init(texture)
        mapMaterial.color = mapColor
        sceneGraph.tableOpticalMaterial = mapMaterial

        var material = PhysicallyBasedMaterial()
        material.baseColor = .init(tint: .white, texture: .init(texture))
        material.roughness = 0.91
        material.metallic = 0.0
        sceneGraph.galeSurfaceMaterial = material
    }

    @MainActor
    private func buildTable() async {
        sceneGraph.tableRoot.name = "tabletop-map-root"
        // Match the immersive scenes' light level; the image-based sky supplies fill.
        addDirectionalSun(to: sceneGraph.tableRoot, intensity: 16_000, shadowDistance: 1.8)
        let tableImageLight = addMartianImageLight(to: sceneGraph.tableRoot)

        guard let asset = missionStore.terrainAsset else {
            addFallbackTerrain(to: sceneGraph.tableRoot)
            return
        }
        let routeGrid = asset.terrain
        let grid = asset.detailedTerrain ?? routeGrid
        let tableSurface: any RealityKit.Material = sceneGraph.tableOpticalMaterial.map { $0 as any RealityKit.Material }
            ?? sceneGraph.galeSurfaceMaterial.map { $0 as any RealityKit.Material }
            ?? terrainMaterial(color: UIColor(red: 0.55, green: 0.29, blue: 0.19, alpha: 1), roughness: 0.94)
        let tableDisk = ModelEntity(
            mesh: .generateCylinder(height: 0.035, radius: 0.49),
            materials: [SimpleMaterial(color: UIColor(white: 0.10, alpha: 1), roughness: 0.78, isMetallic: false)]
        )
        tableDisk.name = "tabletop-base"
        tableDisk.position = SIMD3<Float>(0, TerrainMeshFactory.tabletopBaseCenterY(grid: grid, heightScale: 0.00043), 0)
        sceneGraph.tableRoot.addChild(tableDisk)
        if let mesh = try? TerrainMeshFactory.makeMesh(
            grid: grid,
            widthMeters: 0.88,
            depthMeters: 0.88,
            heightScale: 0.00043,
            circularRadiusMeters: 0.44
        ) {
            let terrain = ModelEntity(
                mesh: mesh,
                materials: [tableSurface]
            )
            terrain.name = "bundled-hirise-tabletop-terrain"
            sceneGraph.tableTerrainEntity = terrain
            addImageLightReceiver(to: terrain, from: tableImageLight)
            sceneGraph.tableRoot.addChild(terrain)
        }
        sceneGraph.tableSlopeOverlay = await makeSlopeOverlay(
            grid: grid,
            width: 0.88,
            depth: 0.88,
            heightScale: 0.00043,
            circularRadius: 0.44,
            lift: 0.0008,
            name: "tabletop-derived-slope-overlay"
        )
        if let overlay = sceneGraph.tableSlopeOverlay { sceneGraph.tableRoot.addChild(overlay) }

        for marker in missionStore.editableMarkers where marker.kind == .airlock || marker.kind == .scienceStop {
            let color: UIColor = switch marker.kind {
            case .airlock, .shelter: .systemGreen
            case .scienceStop: .systemOrange
            case .crew: .systemCyan
            case .waypoint: .systemYellow
            }
            let displayPoint = resample(marker.point, from: routeGrid, to: grid)
            let entity = makeBeacon(name: "map-marker:\(marker.id)", color: color,
            radius: 0.014,
                                    at: mapPosition(displayPoint, grid: grid, lift: 0.025))
            sceneGraph.tableLandmarkMarkers[marker.id] = entity
            sceneGraph.tableRoot.addChild(entity)
        }

        for crew in missionStore.crewTelemetry {
            let point = resample(crew.point, from: routeGrid, to: grid)
            let marker = makeBeacon(name: crew.id, color: .systemCyan, radius: 0.010,
                                    at: mapPosition(point, grid: grid, lift: 0.035))
            sceneGraph.tableCrewMarkers[crew.id] = marker
            sceneGraph.tableRoot.addChild(marker)
        }

        sceneGraph.tableHazardsRoot.isEnabled = false
    }

    @MainActor
    private func buildDrone() async {
        sceneGraph.droneRoot.name = "birdseye-world-root"
        if let sky = sceneGraph.skyMaterial {
            sceneGraph.droneSkyRoot.addChild(makeSkyDome(material: sky))
            addSunDisk(to: sceneGraph.droneSkyRoot)
        }
        addDirectionalSun(to: sceneGraph.droneRoot, intensity: 4_000, shadowDistance: 480)
        let droneImageLight = addMartianImageLight(to: sceneGraph.droneRoot)

        guard let asset = missionStore.terrainAsset else {
            addFallbackTerrain(to: sceneGraph.droneRoot)
            await buildHelmet()
            return
        }
        let grid = asset.nativeTerrain ?? asset.detailedTerrain ?? asset.terrain
        if asset.nativeTerrain != nil {
            sceneGraph.nativeDetailCenter = resample(missionStore.helmetWaypoint, from: asset.terrain, to: grid)
        }
        let terrainWidth = Float(Double(grid.width - 1) * grid.cellSizeMeters)
        let terrainDepth = Float(Double(grid.height - 1) * grid.cellSizeMeters)
        let focus = resample(missionStore.helmetWaypoint, from: asset.terrain, to: grid)
        let hasNative = asset.nativeTerrain != nil
        let data = await Task.detached(priority: .userInitiated) {
            TerrainMeshFactory.makeMeshData(grid: grid, widthMeters: terrainWidth, depthMeters: terrainDepth, heightScale: 1, circularRadiusMeters: min(terrainWidth, terrainDepth) * 0.5, adaptiveNativeDetail: hasNative, detailCenter: focus)
        }.value
        guard !Task.isCancelled, let mesh = try? TerrainMeshFactory.makeMeshResource(data) else {
            addFallbackTerrain(to: sceneGraph.droneRoot)
            addFallbackTerrain(to: sceneGraph.helmetRoot)
            return
        }
        let terrain = ModelEntity(
            mesh: mesh,
            materials: [sceneGraph.galeSurfaceMaterial ?? terrainMaterial(color: UIColor(red: 0.48, green: 0.25, blue: 0.16, alpha: 1), roughness: 0.96)]
        )
        terrain.name = "gale-context-terrain-1-to-1"
        sceneGraph.sharedImmersiveTerrainMesh = mesh
        sceneGraph.droneTerrainEntity = terrain
        addImageLightReceiver(to: terrain, from: droneImageLight)
        sceneGraph.droneRoot.addChild(terrain)
        for crew in missionStore.crewTelemetry {
            let point = resample(crew.point, from: asset.terrain, to: grid)
            let marker = makeBeacon(name: crew.id, color: .systemCyan, radius: 4,
                                    at: terrainPosition(point, grid: grid, width: terrainWidth, depth: terrainDepth, lift: 5))
            sceneGraph.droneCrewMarkers[crew.id] = marker
            sceneGraph.droneRoot.addChild(marker)
        }
        sceneGraph.droneSlopeOverlay = await makeSlopeOverlay(
            grid: asset.detailedTerrain ?? asset.terrain,
            width: terrainWidth,
            depth: terrainDepth,
            lift: 0.035,
            name: "derived-slope-traction-overlay",
            sharedTerrainMesh: mesh
        )
        if let overlay = sceneGraph.droneSlopeOverlay { sceneGraph.droneRoot.addChild(overlay) }

        if let skirtMesh = try? TerrainMeshFactory.makeHorizonSkirt(
            grid: grid,
            innerWidthMeters: Float(Double(grid.width - 1) * grid.cellSizeMeters),
            innerDepthMeters: Float(Double(grid.height - 1) * grid.cellSizeMeters),
            adaptiveNativeDetail: asset.nativeTerrain != nil,
            detailCenter: resample(missionStore.helmetWaypoint, from: asset.terrain, to: grid),
            aerialPitch: .pi * 35 / 180
        ) {
            let skirt = ModelEntity(
                mesh: skirtMesh,
                materials: [UnlitMaterial(color: UIColor(red: 0.42, green: 0.24, blue: 0.18, alpha: 1))]
            )
            skirt.name = "three-ring-low-detail-horizon-skirt"
            sceneGraph.droneHorizonEntity = skirt
            addImageLightReceiver(to: skirt, from: droneImageLight)
            sceneGraph.droneRoot.addChild(skirt)
        }

        updateDroneRoute()
        await buildHelmet()
    }

    @MainActor
    private func buildHelmet() async {
        guard let asset = missionStore.terrainAsset else {
            addFallbackTerrain(to: sceneGraph.helmetRoot)
            return
        }
        let grid = asset.detailedTerrain ?? asset.terrain
        guard let mesh = sceneGraph.sharedImmersiveTerrainMesh ?? (try? TerrainMeshFactory.makeMesh(
                grid: grid,
                widthMeters: Float(Double(grid.width - 1) * grid.cellSizeMeters),
                depthMeters: Float(Double(grid.height - 1) * grid.cellSizeMeters),
                heightScale: 1,
                circularRadiusMeters: min(Float(Double(grid.width - 1) * grid.cellSizeMeters), Float(Double(grid.height - 1) * grid.cellSizeMeters)) * 0.5
              )) else {
            addFallbackTerrain(to: sceneGraph.helmetRoot)
            return
        }
        sceneGraph.helmetRoot.name = "helmet-world-root"
        if let sky = sceneGraph.skyMaterial {
            sceneGraph.helmetSkyRoot.addChild(makeSkyDome(material: sky))
            addSunDisk(to: sceneGraph.helmetSkyRoot)
        }
        addDirectionalSun(to: sceneGraph.helmetRoot, intensity: 4_000, shadowDistance: 110)
        let helmetImageLight = addMartianImageLight(to: sceneGraph.helmetRoot)
        let terrain = ModelEntity(
            mesh: mesh,
            materials: [sceneGraph.galeSurfaceMaterial ?? terrainMaterial(color: UIColor(red: 0.48, green: 0.25, blue: 0.16, alpha: 1), roughness: 0.96)]
        )
        terrain.name = "helmet-gale-context-terrain-1-to-1"
        sceneGraph.helmetTerrainEntity = terrain
        addImageLightReceiver(to: terrain, from: helmetImageLight)
        sceneGraph.helmetRoot.addChild(terrain)
        let width = Float(Double(grid.width - 1) * grid.cellSizeMeters)
        let depth = Float(Double(grid.height - 1) * grid.cellSizeMeters)
        for crew in missionStore.crewTelemetry {
            let point = resample(crew.point, from: asset.terrain, to: grid)
            let marker = makeBeacon(name: crew.id, color: .systemCyan, radius: 0.25,
                                    at: terrainPosition(point, grid: grid, width: width, depth: depth, lift: 0.55))
            sceneGraph.helmetCrewMarkers[crew.id] = marker
            sceneGraph.helmetRoot.addChild(marker)
        }
        sceneGraph.helmetSlopeOverlay = await makeSlopeOverlay(
            grid: grid,
            width: Float(Double(grid.width - 1) * grid.cellSizeMeters),
            depth: Float(Double(grid.height - 1) * grid.cellSizeMeters),
            lift: 0.035,
            name: "helmet-derived-slope-traction-overlay",
            sharedTerrainMesh: mesh
        )
        if let overlay = sceneGraph.helmetSlopeOverlay { sceneGraph.helmetRoot.addChild(overlay) }
        if let skirtMesh = sceneGraph.sharedHorizonMesh ?? (try? TerrainMeshFactory.makeHorizonSkirt(grid: grid, innerWidthMeters: Float(Double(grid.width - 1) * grid.cellSizeMeters), innerDepthMeters: Float(Double(grid.height - 1) * grid.cellSizeMeters))) {
            let skirt = ModelEntity(mesh: skirtMesh, materials: [terrainMaterial(color: UIColor(red: 0.42, green: 0.24, blue: 0.18, alpha: 1), roughness: 0.98)])
            skirt.name = "synthetic-horizon-context"
            sceneGraph.helmetHorizonEntity = skirt
            addImageLightReceiver(to: skirt, from: helmetImageLight)
            sceneGraph.helmetRoot.addChild(skirt)
        }
    }

    @MainActor
    private func makeSlopeOverlay(
        grid: TerrainGrid,
        width: Float,
        depth: Float,
        heightScale: Float = 1,
        circularRadius: Float? = nil,
        lift: Float,
        name: String,
        sharedTerrainMesh: MeshResource? = nil
    ) async -> ModelEntity? {
        do {
            let mesh = try sharedTerrainMesh ?? TerrainMeshFactory.makeSlopeOverlayMesh(
                grid: grid,
                widthMeters: width,
                depthMeters: depth,
                heightScale: heightScale,
                liftMeters: lift,
                circularRadiusMeters: circularRadius
            )
            let image = try TerrainMeshFactory.makeSlopeTexture(grid: grid)
            let texture = try await TextureResource(
                image: image,
                withName: name,
                options: .init(semantic: .color, compression: .default)
            )
            var material = UnlitMaterial()
            var color = material.color
            color.texture = .init(texture)
            material.color = color
            material.blending = .transparent(opacity: 1.0)
            let entity = ModelEntity(mesh: mesh, materials: [material])
            if sharedTerrainMesh != nil { entity.position.y = lift }
            entity.name = name
            entity.isEnabled = missionStore.activeLayers.contains(.slopeTraction)
            return entity
        } catch {
            NSLog("DTM slope overlay unavailable: %@", String(describing: error))
            return nil
        }
    }

    private func makeSkyDome(material: UnlitMaterial) -> ModelEntity {
        let data = TerrainMeshFactory.makeSkyHemisphereData()
        var descriptor = MeshDescriptor(name: "upper-hemisphere-mars-sky")
        descriptor.positions = MeshBuffers.Positions(data.vertices)
        descriptor.textureCoordinates = MeshBuffers.TextureCoordinates(data.textureCoordinates)
        descriptor.primitives = .triangles(data.indices)
        let mesh = (try? MeshResource.generate(from: [descriptor])) ?? .generateSphere(radius: 30_000)
        let dome = ModelEntity(mesh: mesh, materials: [material])
        dome.name = "synthetic-mars-sky-dome"
        // Invert winding to render the panorama from inside the hemisphere.
        dome.scale = SIMD3<Float>(-1, 1, 1)
        return dome
    }

    @discardableResult
    private func addDirectionalSun(to root: Entity, intensity: Float, shadowDistance: Float) -> Entity {
        let sun = Entity()
        sun.name = "mars-sun-key-light"
        sun.components.set(DirectionalLightComponent(color: .white, intensity: intensity))
        var shadow = DirectionalLightComponent.Shadow(
            shadowProjection: .automatic(maximumDistance: shadowDistance),
            depthBias: 1.0
        )
        shadow.cascades = .automatic
        sun.components.set(shadow)
        sun.orientation = visualSunOrientation()
        root.addChild(sun)
        return sun
    }

    private func addMartianImageLight(to root: Entity) -> Entity? {
        guard let environment = sceneGraph.marsSkyAssets?.environment else { return nil }
        let imageLight = Entity()
        imageLight.name = "mars-sky-image-light"
        // Keep the sky probe as a quarter-strength fill; the directional Mars sun provides form.
        var light = ImageBasedLightComponent(source: .single(environment), intensityExponent: -2.0)
        light.inheritsRotation = false
        imageLight.components.set(light)
        root.addChild(imageLight)
        return imageLight
    }

    private func addImageLightReceiver(to entity: Entity, from imageLight: Entity?) {
        guard let imageLight else { return }
        entity.components.set(ImageBasedLightReceiverComponent(imageBasedLight: imageLight))
    }

    /// Visual afternoon preset at Gale (15:00 local solar time, equinox declination).
    /// This controls scene lighting only; it isn't a live Mars ephemeris.
    private func visualSunDirection() -> SIMD3<Float> {
        let latitude = Float(-4.6877 * Double.pi / 180)
        let declination: Float = 0
        let hourAngle = Float.pi / 4
        let east = -cos(declination) * sin(hourAngle)
        let north = sin(declination) * cos(latitude) - cos(declination) * cos(hourAngle) * sin(latitude)
        let up = sin(declination) * sin(latitude) + cos(declination) * cos(hourAngle) * cos(latitude)
        return simd_normalize(SIMD3<Float>(east, up, -north))
    }

    private func visualSunOrientation() -> simd_quatf {
        simd_quatf(from: SIMD3<Float>(0, 0, -1), to: -visualSunDirection())
    }

    private func addSunDisk(to root: Entity) {
        let sun = ModelEntity(
            mesh: .generateSphere(radius: 70),
            materials: [UnlitMaterial(color: UIColor(red: 1, green: 0.78, blue: 0.53, alpha: 1))]
        )
        sun.name = "mars-sun-visible-disk-afternoon-preset"
        // A 0.35 degree apparent disc placed beyond the 24 km demo horizon ring.
        sun.position = visualSunDirection() * 23_000
        root.addChild(sun)
    }

    @MainActor
    private func buildHabitatIfNeeded() async {
        guard !sceneGraph.habitatLoadStarted else { return }
        sceneGraph.habitatLoadStarted = true

        guard let url = Bundle.main.url(forResource: "MarswalkHabitat", withExtension: "usdz") else {
            buildFallbackHabitat()
            return
        }

        do {
            let station = try await Entity(contentsOf: url)
            station.name = "iss-cupola-mars-lookout"
            // The source stage is Z-up and its authored camera is pitched 20° upward.
            // Apply the axis conversion and inverse camera pose so that view starts level
            // through the cupola windows with the user's eye at the authored camera point.
            station.orientation = simd_quatf(angle: -110 * Float.pi / 180, axis: SIMD3<Float>(1, 0, 0))
            station.position = SIMD3<Float>(0, -0.70, 0.126)
            // The bundled interior's panorama and Jezero DTM are not registered to the Gale EVA.
            // Replace them with the selected Gale context and a synthetic Mars sky backdrop.
            findEntity(named: "Jezero_HiRISE_DTM_Terrain", in: station)?.isEnabled = false
            findEntity(named: "Jezero_MastcamZ_360_Panorama", in: station)?.isEnabled = false
            if let sky = sceneGraph.skyMaterial { sceneGraph.habitatRoot.addChild(makeSkyDome(material: sky)) }
            if sceneGraph.skyMaterial != nil { addSunDisk(to: sceneGraph.habitatRoot) }
            addDirectionalSun(to: sceneGraph.habitatRoot, intensity: 26_000, shadowDistance: 360)
            let habitatImageLight = addMartianImageLight(to: sceneGraph.habitatRoot)
            addHabitatFillLighting()
            if let grid = missionStore.terrainAsset?.terrain,
               let landscapeMesh = try? TerrainMeshFactory.makeMesh(
                    grid: grid,
                    widthMeters: Float(Double(grid.width - 1) * grid.cellSizeMeters),
                    depthMeters: Float(Double(grid.height - 1) * grid.cellSizeMeters),
                    heightScale: 0.12
               ) {
                let landscape = ModelEntity(mesh: landscapeMesh, materials: [
                    sceneGraph.galeSurfaceMaterial ?? terrainMaterial(color: UIColor(red: 0.48, green: 0.26, blue: 0.17, alpha: 1), roughness: 0.98)
                ])
                landscape.name = "gale-crater-window-context-approximate"
                landscape.position = SIMD3<Float>(0, -1.7, -550)
                addImageLightReceiver(to: landscape, from: habitatImageLight)
                sceneGraph.habitatRoot.addChild(landscape)
            }
            sceneGraph.habitatRoot.addChild(station)
            buildHabitatTable()
            sceneGraph.habitatLoaded = true
        } catch {
            print("Mars habitat USDZ failed to load: \(error)")
            buildFallbackHabitat()
        }
    }

    private func findEntity(named name: String, in root: Entity) -> Entity? {
        if root.name == name { return root }
        for child in root.children {
            if let match = findEntity(named: name, in: child) { return match }
        }
        return nil
    }

    @MainActor
    private func buildFallbackHabitat() {
        if let sky = sceneGraph.skyMaterial {
            sceneGraph.habitatRoot.addChild(makeSkyDome(material: sky))
            addSunDisk(to: sceneGraph.habitatRoot)
        }
        addDirectionalSun(to: sceneGraph.habitatRoot, intensity: 26_000, shadowDistance: 360)
        let habitatImageLight = addMartianImageLight(to: sceneGraph.habitatRoot)
        addHabitatFillLighting()
        addBox(size: SIMD3(4.8, 0.18, 5.6), position: SIMD3(0, -1.8, -0.6), color: UIColor(white: 0.18, alpha: 1), name: "habitat-deck", to: sceneGraph.habitatRoot)
        addBox(size: SIMD3(0.18, 3.2, 5.6), position: SIMD3(-2.35, -0.12, -0.6), color: UIColor(white: 0.28, alpha: 1), name: "port-wall", to: sceneGraph.habitatRoot)
        addBox(size: SIMD3(0.18, 3.2, 5.6), position: SIMD3(2.35, -0.12, -0.6), color: UIColor(white: 0.28, alpha: 1), name: "starboard-wall", to: sceneGraph.habitatRoot)
        addBox(size: SIMD3(4.8, 0.24, 0.18), position: SIMD3(0, 1.4, -3.3), color: UIColor(white: 0.34, alpha: 1), name: "window-header", to: sceneGraph.habitatRoot)
        addBox(size: SIMD3(4.8, 0.24, 0.18), position: SIMD3(0, -1.45, -3.3), color: UIColor(white: 0.34, alpha: 1), name: "window-sill", to: sceneGraph.habitatRoot)
        addBox(size: SIMD3(0.22, 2.8, 0.18), position: SIMD3(-2.29, 0, -3.3), color: UIColor(white: 0.34, alpha: 1), name: "window-port-frame", to: sceneGraph.habitatRoot)
        addBox(size: SIMD3(0.22, 2.8, 0.18), position: SIMD3(2.29, 0, -3.3), color: UIColor(white: 0.34, alpha: 1), name: "window-starboard-frame", to: sceneGraph.habitatRoot)

        if let grid = missionStore.terrainAsset?.terrain,
           let mesh = try? TerrainMeshFactory.makeMesh(
            grid: grid,
            widthMeters: Float(Double(grid.width - 1) * grid.cellSizeMeters),
            depthMeters: Float(Double(grid.height - 1) * grid.cellSizeMeters),
            heightScale: 1
           ) {
            let landscape = ModelEntity(mesh: mesh, materials: [SimpleMaterial(color: UIColor(red: 0.52, green: 0.26, blue: 0.15, alpha: 1), roughness: 0.95, isMetallic: false)])
            landscape.name = "outside-habitat-gale-context"
            landscape.position = SIMD3<Float>(0, -12, -525)
            addImageLightReceiver(to: landscape, from: habitatImageLight)
            sceneGraph.habitatRoot.addChild(landscape)
        }
        buildHabitatTable()
    }

    @MainActor
    private func buildHabitatTable() {
        guard !sceneGraph.habitatMapBuilt,
              let grid = missionStore.terrainAsset?.terrain,
              let mesh = try? TerrainMeshFactory.makeMesh(
                grid: grid,
                widthMeters: 0.72,
                depthMeters: 0.72,
                heightScale: 0.00043,
                circularRadiusMeters: 0.36
              ) else { return }
        sceneGraph.habitatMapBuilt = true

        let disk = ModelEntity(
            mesh: .generateCylinder(height: 0.025, radius: 0.39),
            materials: [SimpleMaterial(color: UIColor(white: 0.10, alpha: 1), roughness: 0.8, isMetallic: false)]
        )
        disk.position = SIMD3<Float>(0, -0.585, -0.95)
        sceneGraph.habitatRoot.addChild(disk)

        let terrain = ModelEntity(
            mesh: mesh,
            materials: [sceneGraph.galeSurfaceMaterial ?? terrainMaterial(color: UIColor(red: 0.56, green: 0.29, blue: 0.19, alpha: 1), roughness: 0.94)]
        )
        terrain.name = "habitat-gale-tabletop-context"
        terrain.position = SIMD3<Float>(0, -0.565, -0.95)
        addImageLightReceiver(to: terrain, from: sceneGraph.habitatRoot.children.first(where: { $0.name == "mars-sky-image-light" }))
        sceneGraph.habitatRoot.addChild(terrain)

        for marker in missionStore.editableMarkers {
            let color: UIColor = marker.kind == .scienceStop ? .systemOrange : (marker.kind == .crew ? .systemCyan : .systemGreen)
            let pin = makeBeacon(
                name: "habitat-marker:\(marker.id)",
                color: color,
                radius: marker.kind == .crew ? 0.008 : 0.011,
                at: mapPosition(marker.point, grid: grid, width: 0.72, depth: 0.72, lift: 0.016)
            )
            pin.position += SIMD3<Float>(0, -0.565, -0.95)
            sceneGraph.habitatMissionMarkers[marker.id] = pin
            sceneGraph.habitatRoot.addChild(pin)
        }
    }

    @MainActor
    private func addHabitatFillLighting() {
        for (index, position) in [SIMD3<Float>(-1.3, 1.45, -0.8), SIMD3<Float>(1.3, 1.45, -0.8), SIMD3<Float>(0, 1.45, 0.9)].enumerated() {
            let cabinLight = Entity()
            cabinLight.name = "habitat-cabin-fill-\(index)"
            cabinLight.position = position
            cabinLight.components.set(PointLightComponent(
                color: UIColor(red: 1.0, green: 0.78, blue: 0.58, alpha: 1),
                intensity: 520,
                attenuationRadius: 4.5
            ))
            sceneGraph.habitatRoot.addChild(cabinLight)
        }
    }

    @MainActor
    private func updateScene(attachments: RealityViewAttachments) {
        if sceneGraph.renderedStage != missionStore.stage {
            transition(to: missionStore.stage)
        }

        sceneGraph.globeRoot.orientation = simd_quatf(angle: Float(globeRotation + dragRotation.width), axis: SIMD3<Float>(0, 1, 0)) * simd_quatf(angle: Float(max(-1.4, min(1.4, globePitch + dragRotation.height))), axis: SIMD3<Float>(1, 0, 0))
        // The Mars mesh rotates independently; keep direct illumination fixed in world space.
        if let globeSunLight = sceneGraph.globeSunLight {
            globeSunLight.orientation = simd_mul(
                simd_inverse(sceneGraph.globeRoot.orientation),
                visualSunOrientation()
            )
        }
        if let material = sceneGraph.globeMaterials[missionStore.selectedGlobeLayer] {
            sceneGraph.globeModel?.model?.materials = [material]
        }
        updateLocalOpticalLayer()
        updateGlobeMarkerVisibility()
        attachGlobeLabels(from: attachments)
        updateCrewPositions()
        updateCrewCard(attachments: attachments)
        updateLandmarkCard(attachments: attachments)
        updateHelmetHUD(attachments: attachments)
        updateEVADrawer(attachments: attachments)
        updateRadioCommsPill(attachments: attachments)
        updateHelmetPosition()
        updateInspectionPosition()
        updateEmergencyAlert(attachments: attachments)
        updateAlertAudio()

        if sceneGraph.lastRenderedRoute != missionStore.routeComparison {
            updateDroneRoute()
            sceneGraph.lastRenderedRoute = missionStore.routeComparison
        }
        if isPlanningVolume {
            if missionStore.emergencyDemo != nil {
                if sceneGraph.dustEffect == nil || sceneGraph.dustReduceMotion != reduceMotion {
                    sceneGraph.dustEffect?.removeFromParent()
                    let dust = DustStormEffect.make(reduceMotion: reduceMotion)
                    sceneGraph.tableRoot.addChild(dust)
                    sceneGraph.dustEffect = dust
                    sceneGraph.dustReduceMotion = reduceMotion
                }
                sceneGraph.dustEffect?.isEnabled = missionStore.stage == .tabletop
            } else {
                sceneGraph.dustEffect?.removeFromParent()
                sceneGraph.dustEffect = nil
            }
        }
        sceneGraph.tableHazardsRoot.isEnabled = missionStore.activeLayers.contains(.terrainClass)
        sceneGraph.layerOverlayEntity?.isEnabled = missionStore.stage == .tabletop
        sceneGraph.tableSlopeOverlay?.isEnabled = missionStore.stage == .tabletop && missionStore.activeLayers.contains(.slopeTraction)
        sceneGraph.droneSlopeOverlay?.isEnabled = missionStore.stage == .drone && missionStore.activeLayers.contains(.slopeTraction)
        sceneGraph.helmetSlopeOverlay?.isEnabled = missionStore.stage == .helmet && missionStore.activeLayers.contains(.slopeTraction)
        sceneGraph.habitatMapOverlayEntity?.isEnabled = missionStore.stage == .habitat
        sceneGraph.helmetHUD?.isEnabled = missionStore.stage == .helmet
    }

    @MainActor
    private func attachGlobeLabels(from attachments: RealityViewAttachments) {
        for landmark in missionStore.landmarks {
            guard sceneGraph.globeLabelIDs.contains(landmark.id) == false,
                  let marker = sceneGraph.globeLandmarkMarkers[landmark.id],
                  let label = attachments.entity(for: "globe-label:\(landmark.id)") else { continue }
            label.components.set(BillboardComponent())
            label.name = "landmark-label"
            // The attachment bounds cover the dot; the hover banner is an
            // overlay and must not be used as the dot's target width.
            label.scale = attachmentScale(label, targetWidth: 0.024)
            marker.addChild(label)
            // The SwiftUI button owns gaze and pinch for this landmark.
            marker.components.remove(CollisionComponent.self)
            marker.model = nil
            for child in Array(marker.children) where child is ModelEntity && !child.name.hasSuffix("-surface-leader") {
                child.removeFromParent()
            }
            sceneGraph.globeLabelIDs.insert(landmark.id)
        }
    }

    @MainActor
    private func updateLocalOpticalLayer() {
        let isVisible = missionStore.activeLayers.contains(.optical)
        guard sceneGraph.lastLocalOpticalVisibility != isVisible else { return }
        sceneGraph.lastLocalOpticalVisibility = isVisible

        let material = isVisible
            ? (sceneGraph.galeSurfaceMaterial ?? terrainMaterial(color: UIColor(red: 0.55, green: 0.29, blue: 0.19, alpha: 1), roughness: 0.94))
            : terrainMaterial(color: UIColor(red: 0.43, green: 0.28, blue: 0.20, alpha: 1), roughness: 0.97)
        if let tableTerrain = sceneGraph.tableTerrainEntity {
            let mapMaterial: any RealityKit.Material = isVisible
                ? (sceneGraph.tableOpticalMaterial.map { $0 as any RealityKit.Material }
                    ?? terrainMaterial(color: UIColor(red: 0.55, green: 0.29, blue: 0.19, alpha: 1), roughness: 0.94))
                : terrainMaterial(color: UIColor(red: 0.43, green: 0.28, blue: 0.20, alpha: 1), roughness: 0.97)
            tableTerrain.model?.materials = [mapMaterial]
        }
        for entity in [sceneGraph.droneTerrainEntity, sceneGraph.helmetTerrainEntity].compactMap({ $0 }) {
            entity.model?.materials = [material]
        }
    }

    @MainActor
    private func fitTable(in viewBounds: BoundingBox) {
        guard sceneGraph.tableTerrainEntity != nil else { return }
        let local = sceneGraph.tableRoot.visualBounds(recursive: true, relativeTo: sceneGraph.tableRoot, excludeInactive: false)
        // RealityView's scene origin is centered in depth. GeometryReader3D's
        // local frame starts at zero on that axis, so remove its depth midpoint
        // before fitting scene entities to the volume.
        let depthCenter = (viewBounds.min.z + viewBounds.max.z) * 0.5
        let depthOffset = SIMD3<Float>(0, 0, depthCenter)
        guard let transform = TableVolumeFit.transform(viewMin: viewBounds.min - depthOffset, viewMax: viewBounds.max - depthOffset,
                                                       contentMin: local.min, contentMax: local.max) else { return }
        let old = sceneGraph.tableTargetTransform
        guard simd_distance(old.translation, transform.translation) > 0.001 ||
              simd_distance(old.scale, transform.scale) > 0.001 else { return }
        sceneGraph.tableTargetTransform = transform
        if missionStore.stage == .tabletop {
            sceneGraph.tableRoot.transform = transform
        }
        #if DEBUG
        NSLog("Table volume bounds min=%@ max=%@ content min=%@ max=%@ scale=%f",
              String(describing: viewBounds.min), String(describing: viewBounds.max),
              String(describing: local.min), String(describing: local.max), transform.scale.x)
        #endif
    }

    @MainActor
    private func transition(to newStage: MissionStage) {
        let oldStage = sceneGraph.renderedStage
        sceneGraph.renderedStage = newStage
        sceneGraph.transitionTask?.cancel()
        if isPlanningVolume && newStage == .tabletop && oldStage != .tabletop {
            // Keep the content at its fitted pose while it fades in. A translation
            // to a hard-coded second pose could exit the actual volume mid-animation.
            sceneGraph.tableRoot.transform = sceneGraph.tableTargetTransform
        }
        let incomingWasVisible = root(for: newStage)?.isEnabled ?? false
        let incomingSkyWasVisible = skyRoot(for: newStage)?.isEnabled ?? false
        for stage in MissionStage.allCases {
            root(for: stage)?.isEnabled = stage == newStage || stage == oldStage
        }
        sceneGraph.stageEntryEye = sceneGraph.viewerPosition
        sceneGraph.stageEntryForward = sceneGraph.viewerForward
        sceneGraph.droneSkyRoot.position = sceneGraph.stageEntryEye
        sceneGraph.helmetSkyRoot.position = sceneGraph.stageEntryEye
        sceneGraph.droneSkyRoot.isEnabled = newStage == .drone || oldStage == .drone
        sceneGraph.helmetSkyRoot.isEnabled = newStage == .helmet || oldStage == .helmet
        if let newRoot = root(for: newStage) {
            let oldRoot = oldStage.flatMap { $0 == newStage ? nil : root(for: $0) }
            let newSky = skyRoot(for: newStage)
            let oldSky = oldStage.flatMap { $0 == newStage ? nil : skyRoot(for: $0) }
            // Continue from the currently displayed opacity when a new stage
            // interrupts a fade, instead of flashing either scene to 0 or 1.
            let incomingStart = oldStage != nil && incomingWasVisible ? (newRoot.components[OpacityComponent.self]?.opacity ?? 1) : 0
            let outgoingStart = oldRoot?.components[OpacityComponent.self]?.opacity ?? 1
            let skyIncomingStart = oldStage != nil && incomingSkyWasVisible ? (newSky?.components[OpacityComponent.self]?.opacity ?? 1) : 0
            let skyOutgoingStart = oldSky?.components[OpacityComponent.self]?.opacity ?? 1
            newRoot.components.set(OpacityComponent(opacity: incomingStart))
            newSky?.components.set(OpacityComponent(opacity: skyIncomingStart))
            sceneGraph.transitionTask = Task { @MainActor in
                for step in 1...20 {
                    try? await Task.sleep(for: .milliseconds(30))
                    guard !Task.isCancelled else { return }
                    let opacity = Float(step) / 20
                    newRoot.components.set(OpacityComponent(opacity: incomingStart + (1 - incomingStart) * opacity))
                    newSky?.components.set(OpacityComponent(opacity: skyIncomingStart + (1 - skyIncomingStart) * opacity))
                    oldRoot?.components.set(OpacityComponent(opacity: outgoingStart * (1 - opacity)))
                    oldSky?.components.set(OpacityComponent(opacity: skyOutgoingStart * (1 - opacity)))
                }
                oldRoot?.isEnabled = false
                oldSky?.isEnabled = false
                #if DEBUG
                NSLog("Mars transition complete stage=%@ rootEnabled=%@ opacity=%f skyEnabled=%@ skyOpacity=%f", newStage.rawValue, String(newRoot.isEnabled), newRoot.components[OpacityComponent.self]?.opacity ?? -1, String(newSky?.isEnabled ?? false), newSky?.components[OpacityComponent.self]?.opacity ?? -1)
                #endif
            }
        }
        sceneGraph.lastInspectionOffset = nil
        sceneGraph.lastHelmetWaypoint = nil
        sceneGraph.lastHelmetPlaybackState = nil

    }

    private func skyRoot(for stage: MissionStage) -> Entity? {
        switch stage {
        case .drone: sceneGraph.droneSkyRoot
        case .helmet: sceneGraph.helmetSkyRoot
        default: nil
        }
    }

    private func root(for stage: MissionStage) -> Entity? {
        switch stage {
        case .globe: sceneGraph.globeRoot
        case .tabletop: sceneGraph.tableRoot
        case .drone: sceneGraph.droneRoot
        case .helmet: sceneGraph.helmetRoot
        case .habitat: sceneGraph.habitatRoot
        }
    }

    private func anchor(for stage: MissionStage) -> Entity? {
        switch stage {
        case .globe: sceneGraph.globeAnchor
        case .tabletop: sceneGraph.tableAnchor
        case .drone: sceneGraph.droneAnchor
        case .helmet: sceneGraph.helmetAnchor
        case .habitat: sceneGraph.habitatAnchor
        }
    }

    private func visiblePosition(for stage: MissionStage) -> SIMD3<Float> {
        switch stage {
        case .globe: .zero
        case .tabletop: SIMD3<Float>(0, 0.025, 0)
        case .drone, .helmet, .habitat: .zero
        }
    }

    private func offstagePosition(for stage: MissionStage) -> SIMD3<Float> {
        switch stage {
        case .globe: SIMD3<Float>(0, 0.32, -0.08)
        case .tabletop: SIMD3<Float>(0, -0.32, 0)
        case .drone: SIMD3<Float>(0, 0, 18)
        case .helmet: SIMD3<Float>(0, 0, 12)
        case .habitat: SIMD3<Float>(0, 0, 18)
        }
    }

    private func controlPosition(for stage: MissionStage) -> SIMD3<Float> {
        switch stage {
        case .globe: SIMD3<Float>(0, 0.88, -1.12)
        case .tabletop: SIMD3<Float>(0, 0.92, -1.12)
        case .drone, .helmet, .habitat: SIMD3<Float>(0, 0.92, -1.12)
        }
    }

    @MainActor
    private func updateCrewCard(attachments: RealityViewAttachments) {
        guard let card = attachments.entity(for: "crew-info-card") else { return }
        let marker: ModelEntity?
        switch missionStore.stage {
        case .globe: marker = sceneGraph.globeCrewMarkers[missionStore.selectedCrewID]
        case .tabletop: marker = sceneGraph.tableCrewMarkers[missionStore.selectedCrewID]
        case .habitat: marker = sceneGraph.habitatMissionMarkers[missionStore.selectedCrewID]
        case .drone: marker = sceneGraph.droneCrewMarkers[missionStore.selectedCrewID]
        case .helmet: marker = sceneGraph.helmetCrewMarkers[missionStore.selectedCrewID]
        }

        guard missionStore.isCrewCardVisible, let marker else {
            if sceneGraph.cardOwner != nil { card.removeFromParent(); sceneGraph.cardOwner = nil }
            return
        }
        let globeFallback = missionStore.stage == .globe && !marker.isEnabled
        let owner = "\(missionStore.stage.rawValue)-\(missionStore.selectedCrewID)-\(globeFallback)"
        if sceneGraph.cardOwner != owner {
            card.removeFromParent()
            if globeFallback { sceneGraph.globeRoot.addChild(card) } else { marker.addChild(card) }
            card.components.set(BillboardComponent())
            let width: Float = missionStore.stage == .drone ? 60 : (missionStore.stage == .helmet ? 0.8 : 0.28)
            card.scale = attachmentScale(card, targetWidth: width)
            card.position = missionStore.stage == .drone ? SIMD3<Float>(12, 25, 0) : SIMD3<Float>(0.12, 0.075, 0.06)
            sceneGraph.cardOwner = owner
        }
        if missionStore.stage == .globe {
            let viewer = sceneGraph.globeRoot.convert(position: sceneGraph.viewerPosition, from: nil)
            let direction = simd_length_squared(viewer) > 0.0001 ? simd_normalize(viewer) : SIMD3<Float>(0, 0, 1)
            if globeFallback {
                // The EVA button must remain useful while the marker is on the far side.
                card.position = direction * (GlobePinLayout.globeRadiusMeters + 0.15) + SIMD3<Float>(0, 0.08, 0)
            } else if card.parent === marker {
                card.position = simd_normalize(marker.position) * 0.10 + SIMD3<Float>(0, 0.07, 0)
            }
        }
    }

    @MainActor
    private func updateLandmarkCard(attachments: RealityViewAttachments) {
        guard let card = attachments.entity(for: "landmark-info-card") else { return }
        guard missionStore.isLandmarkCardVisible,
              missionStore.stage == .globe,
              let marker = sceneGraph.globeLandmarkMarkers[missionStore.selectedLandmarkID],
              marker.isEnabled else {
            if sceneGraph.landmarkCardOwner != nil {
                card.removeFromParent()
                sceneGraph.landmarkCardOwner = nil
            }
            return
        }
        let owner = missionStore.selectedLandmarkID
        if sceneGraph.landmarkCardOwner != owner {
            card.removeFromParent()
            marker.addChild(card)
            card.components.set(BillboardComponent())
            card.scale = attachmentScale(card, targetWidth: 0.34)
            sceneGraph.landmarkCardOwner = owner
        }
        // A radial offset alone clips a wide billboard at the limb. Place the
        // card's plane in front of the globe from the wearer's current direction.
        let viewer = sceneGraph.globeRoot.convert(position: sceneGraph.viewerPosition, from: nil)
        card.position = GlobePinLayout.calloutOffset(markerPosition: marker.position, viewerPosition: viewer)
    }

    @MainActor
    private func updateGlobeMarkerVisibility() {
        let localViewer = sceneGraph.globeRoot.convert(position: sceneGraph.viewerPosition, from: nil)
        let viewDirection = simd_length_squared(localViewer) > 0.0001
            ? simd_normalize(localViewer) : SIMD3<Float>(0, 0, 1)
        for marker in sceneGraph.globeLandmarkMarkers.values {
            let normal = simd_normalize(marker.position)
            marker.isEnabled = simd_dot(normal, viewDirection) >= 0.15
        }
        // A selected marker may rotate behind the planet. In that case its
        // card is hidden too, so restore the remaining labels and avoid
        // leaving the globe without any selectable landmarks.
        let selectedCardIsVisible = missionStore.isLandmarkCardVisible
            && missionStore.stage == .globe
            && (sceneGraph.globeLandmarkMarkers[missionStore.selectedLandmarkID]?.isEnabled ?? false)
        for marker in sceneGraph.globeLandmarkMarkers.values {
            if let label = marker.findEntity(named: "landmark-label") {
                label.isEnabled = !selectedCardIsVisible
                label.position = GlobePinLayout.calloutOffset(markerPosition: marker.position, viewerPosition: localViewer)
            }
        }
        let viewDirectionForCrew = viewDirection
        for marker in sceneGraph.globeCrewMarkers.values {
            marker.isEnabled = simd_dot(simd_normalize(marker.position), viewDirectionForCrew) >= 0.15
        }
    }

    @MainActor
    private func updateHelmetHUD(attachments: RealityViewAttachments) {
        guard let hud = attachments.entity(for: "helmet-hud") else { return }
        if sceneGraph.helmetHUD == nil {
            hud.components.set(BillboardComponent())
            hud.scale = attachmentScale(hud, targetWidth: 0.24)
            hud.position = SIMD3<Float>(0, 0.28, -1.10)
            sceneGraph.controlsAnchor.addChild(hud)
            sceneGraph.helmetHUD = hud
        }
        hud.isEnabled = missionStore.stage == .helmet
    }

    @MainActor
    private func updateEVADrawer(attachments: RealityViewAttachments) {
        guard let drawer = attachments.entity(for: "eva-drawer") else {
            if let existing = sceneGraph.evaDrawerEntity {
                existing.removeFromParent()
                sceneGraph.evaDrawerEntity = nil
            }
            return
        }
        if sceneGraph.evaDrawerEntity !== drawer {
            drawer.components.set(BillboardComponent())
            drawer.scale = attachmentScale(drawer, targetWidth: 0.50)
            drawer.position = SIMD3<Float>(0.82, -0.06, -0.91)
            sceneGraph.dockRoot.addChild(drawer)
            sceneGraph.evaDrawerEntity = drawer
        }
        drawer.isEnabled = missionStore.isEVADrawerVisible
    }

    @MainActor
    private func updateEmergencyAlert(attachments: RealityViewAttachments) {
        guard let alert = attachments.entity(for: "emergency-alert") else { return }
        if sceneGraph.alertEntity !== alert {
            alert.components.set(BillboardComponent())
            alert.scale = attachmentScale(alert, targetWidth: 0.72)
            alert.position = SIMD3<Float>(0, 0.39, -0.88)
            sceneGraph.dockRoot.addChild(alert)
            sceneGraph.alertEntity = alert
        }
        alert.isEnabled = missionStore.activeAlert != nil
    }

    @MainActor
    private func updateRadioCommsPill(attachments: RealityViewAttachments) {
        guard let pill = attachments.entity(for: "radio-comms-pill") else {
            sceneGraph.radioCommsEntity?.removeFromParent()
            sceneGraph.radioCommsEntity = nil
            return
        }
        if sceneGraph.radioCommsEntity !== pill {
            pill.components.set(BillboardComponent())
            pill.scale = attachmentScale(pill, targetWidth: 0.62)
            pill.position = SIMD3<Float>(0, 0.54, -0.88)
            sceneGraph.dockRoot.addChild(pill)
            sceneGraph.radioCommsEntity = pill
        }
    }

    @MainActor
    private func updateAlertAudio() {
        guard let alert = missionStore.activeAlert else {
            sceneGraph.lastPlayedAlert = nil
            return
        }
        guard sceneGraph.lastPlayedAlert != alert else { return }
        sceneGraph.lastPlayedAlert = alert
        guard let url = Bundle.main.url(forResource: "SafetyAlert", withExtension: "wav", subdirectory: "MarsData")
            ?? Bundle.main.url(forResource: "SafetyAlert", withExtension: "wav") else { return }
        let entity = sceneGraph.alertAudioEntity
        Task { @MainActor in
            do {
                let resource = try await AudioFileResource(contentsOf: url, withName: "SafetyAlert", configuration: .init(shouldLoop: false))
                entity.playAudio(resource)
            } catch {
                print("Spatial safety alert audio unavailable: \(error)")
            }
        }
    }

    @MainActor
    private func updateCrewPositions() {
        guard let asset = missionStore.terrainAsset else { return }
        let routeGrid = asset.terrain
        let displayGrid = asset.detailedTerrain ?? routeGrid
        let width = Float(Double(displayGrid.width - 1) * displayGrid.cellSizeMeters)
        let depth = Float(Double(displayGrid.height - 1) * displayGrid.cellSizeMeters)
        for crew in missionStore.crewTelemetry {
            let displayPoint = resample(crew.point, from: routeGrid, to: displayGrid)
            let globeSurface = globePosition(for: approximateCoordinate(for: crew.point), radius: GlobePinLayout.globeRadiusMeters)
            sceneGraph.globeCrewMarkers[crew.id]?.position = GlobePinLayout.beaconPosition(markerID: crew.id, surfacePosition: globeSurface)
            sceneGraph.tableLandmarkMarkers[crew.id]?.position = mapPosition(displayPoint, grid: displayGrid, lift: 0.025)
            sceneGraph.tableCrewMarkers[crew.id]?.position = mapPosition(displayPoint, grid: displayGrid, lift: 0.035)
            sceneGraph.droneCrewMarkers[crew.id]?.position = terrainPosition(displayPoint, grid: displayGrid, width: width, depth: depth, lift: 4)
            sceneGraph.helmetCrewMarkers[crew.id]?.position = terrainPosition(displayPoint, grid: displayGrid, width: width, depth: depth, lift: 0.55)
        }
        for marker in missionStore.editableMarkers where marker.kind != .crew {
            let displayPoint = resample(marker.point, from: routeGrid, to: displayGrid)
            sceneGraph.tableLandmarkMarkers[marker.id]?.position = mapPosition(displayPoint, grid: displayGrid, lift: 0.025)
            if let habitatMarker = sceneGraph.habitatMissionMarkers[marker.id] {
                let point = mapPosition(marker.point, grid: routeGrid, width: 0.72, depth: 0.72, lift: 0.016)
                habitatMarker.position = point + SIMD3<Float>(0, -0.565, -0.95)
            }
        }
        for crew in missionStore.crewTelemetry {
            if let habitatMarker = sceneGraph.habitatMissionMarkers[crew.id] {
                let point = mapPosition(crew.point, grid: routeGrid, width: 0.72, depth: 0.72, lift: 0.016)
                habitatMarker.position = point + SIMD3<Float>(0, -0.565, -0.95)
            }
        }
    }

    @MainActor
    private func updateDronePlayback() {
        guard missionStore.stage == .drone else { return }
        updateCrewPositions()
    }

    @MainActor
    private func updateInspectionPosition() {
        guard missionStore.stage == .drone, let asset = missionStore.terrainAsset,
              sceneGraph.lastInspectionOffset != missionStore.inspectionOffset || sceneGraph.lastAerialZoom != missionStore.aerialZoom || sceneGraph.lastAerialRoute != missionStore.routeComparison else { return }
        let entering = sceneGraph.lastInspectionOffset == nil
        sceneGraph.lastInspectionOffset = missionStore.inspectionOffset
        sceneGraph.lastAerialZoom = missionStore.aerialZoom
        sceneGraph.lastAerialRoute = missionStore.routeComparison
        let routeGrid = asset.terrain
        let grid = asset.nativeTerrain ?? asset.detailedTerrain ?? routeGrid
        let route = missionStore.routeComparison
        let framing = AerialOverview.frame(points: (route?.routed.path ?? []) + (route?.straightLinePath ?? []), cellSize: routeGrid.cellSizeMeters, fallback: missionStore.helmetWaypoint)
        let target = GridPoint(x: min(routeGrid.width - 1, max(0, framing.center.x + missionStore.inspectionOffset.x)), y: min(routeGrid.height - 1, max(0, framing.center.y + missionStore.inspectionOffset.y)))
        let point = resample(target, from: routeGrid, to: grid)
        requestNativeDetail(around: point, grid: grid, available: asset.nativeTerrain != nil)
        let position = terrainPosition(point, grid: grid, width: Float(Double(grid.width - 1) * grid.cellSizeMeters), depth: Float(Double(grid.height - 1) * grid.cellSizeMeters), lift: 0)
        let altitude = Float(AerialOverview.altitude(framing.altitude, zoom: missionStore.aerialZoom))
        let yaw = simd_quatf(from: SIMD3<Float>(0, 0, -1), to: sceneGraph.stageEntryForward)
        let pitch = simd_quatf(angle: Float.pi * 35 / 180, axis: SIMD3<Float>(1, 0, 0))
        let rotation = yaw * pitch
        // Move the landscape, not the wearer. Center it below and in front of
        // the tracked pose so the route reads as a close oblique map.
        let translation = sceneGraph.stageEntryEye + sceneGraph.stageEntryForward * (altitude * 0.85)
            + SIMD3<Float>(0, -altitude * 0.15, 0) - rotation.act(position)
        let transform = Transform(scale: .one, rotation: rotation, translation: translation)
        if entering {
            sceneGraph.droneRoot.transform = transform
        } else {
            sceneGraph.droneRoot.move(to: transform, relativeTo: sceneGraph.droneAnchor, duration: 0.4, timingFunction: .easeInOut)
        }
    }

    @MainActor
    private func updateHelmetPosition() {
        let waypoint = missionStore.liveEVAPlayback ? (missionStore.crewTelemetry.first?.point ?? missionStore.helmetWaypoint) : missionStore.helmetWaypoint
        guard missionStore.stage == .helmet, let asset = missionStore.terrainAsset,
              sceneGraph.lastHelmetWaypoint != waypoint || sceneGraph.lastHelmetPlaybackState != missionStore.liveEVAPlayback else { return }
        let entering = sceneGraph.lastHelmetWaypoint == nil
        sceneGraph.lastHelmetWaypoint = waypoint
        sceneGraph.lastHelmetPlaybackState = missionStore.liveEVAPlayback
        let grid = asset.nativeTerrain ?? asset.detailedTerrain ?? asset.terrain
        let displayWaypoint = resample(waypoint, from: asset.terrain, to: grid)
        requestNativeDetail(around: displayWaypoint, grid: grid, available: asset.nativeTerrain != nil)
        let position = terrainPosition(
            displayWaypoint,
            grid: grid,
            width: Float(Double(grid.width - 1) * grid.cellSizeMeters),
            depth: Float(Double(grid.height - 1) * grid.cellSizeMeters),
            lift: 0
        )
        let translation = ImmersiveTerrainPlacement.translation(eye: sceneGraph.stageEntryEye, terrainPoint: position, clearance: HelmetTerrainPlacement.eyeHeightMeters)
        if entering {
            sceneGraph.helmetRoot.position = translation
        } else {
            sceneGraph.helmetRoot.move(to: Transform(translation: translation), relativeTo: sceneGraph.helmetAnchor, duration: 0.14, timingFunction: .easeInOut)
        }
    }

    @MainActor
    private func requestNativeDetail(around point: GridPoint, grid: TerrainGrid, available: Bool) {
        guard available, let current = sceneGraph.nativeDetailCenter else { return }
        sceneGraph.desiredDetailCenter = point
        let dx = point.x - current.x, dy = point.y - current.y
        guard dx * dx + dy * dy > 90 * 90 else { return }
        guard sceneGraph.nativeDetailTask == nil else { return }
        let width = Float(Double(grid.width - 1) * grid.cellSizeMeters)
        let depth = Float(Double(grid.height - 1) * grid.cellSizeMeters)
        sceneGraph.nativeDetailTask = Task { @MainActor in
            let requested = point
            let data = await Task.detached(priority: .userInitiated) {
                TerrainMeshFactory.makeMeshData(grid: grid, widthMeters: width, depthMeters: depth, heightScale: 1, circularRadiusMeters: min(width, depth) * 0.5, adaptiveNativeDetail: true, detailCenter: requested)
            }.value
            guard !Task.isCancelled else { return }
            guard let mesh = try? TerrainMeshFactory.makeMeshResource(data),
                  let horizon = try? TerrainMeshFactory.makeHorizonSkirt(grid: grid, innerWidthMeters: width, innerDepthMeters: depth, adaptiveNativeDetail: true, detailCenter: requested),
                  let aerialHorizon = try? TerrainMeshFactory.makeHorizonSkirt(grid: grid, innerWidthMeters: width, innerDepthMeters: depth, adaptiveNativeDetail: true, detailCenter: requested, aerialPitch: .pi * 35 / 180) else {
                NSLog("Unable to update native terrain detail; keeping the previous mesh.")
                sceneGraph.nativeDetailTask = nil
                sceneGraph.desiredDetailCenter = nil
                return
            }
            sceneGraph.droneTerrainEntity?.model?.mesh = mesh
            sceneGraph.helmetTerrainEntity?.model?.mesh = mesh
            sceneGraph.droneSlopeOverlay?.model?.mesh = mesh
            sceneGraph.helmetSlopeOverlay?.model?.mesh = mesh
            sceneGraph.droneHorizonEntity?.model?.mesh = aerialHorizon
            sceneGraph.helmetHorizonEntity?.model?.mesh = horizon
            sceneGraph.sharedImmersiveTerrainMesh = mesh
            sceneGraph.sharedHorizonMesh = horizon
            sceneGraph.nativeDetailCenter = requested
            sceneGraph.nativeDetailTask = nil
            if let desired = sceneGraph.desiredDetailCenter {
                requestNativeDetail(around: desired, grid: grid, available: true)
            }
        }
    }

    @MainActor
    private func updateDroneRoute() {
        guard let asset = missionStore.terrainAsset else { return }
        sceneGraph.tableRoutedPath?.removeFromParent()
        sceneGraph.tableStraightPath?.removeFromParent()
        sceneGraph.droneRoutedPath?.removeFromParent()
        sceneGraph.droneStraightPath?.removeFromParent()
        sceneGraph.helmetRoutedPath?.removeFromParent()
        sceneGraph.helmetStraightPath?.removeFromParent()
        sceneGraph.droneRoot.findEntity(named: "drone-route-destination")?.removeFromParent()
        sceneGraph.helmetRoot.findEntity(named: "helmet-route-destination")?.removeFromParent()

        guard let comparison = missionStore.routeComparison else {
            sceneGraph.tableRoutedPath = nil
            sceneGraph.tableStraightPath = nil
            sceneGraph.droneRoutedPath = nil
            sceneGraph.droneStraightPath = nil
            sceneGraph.helmetRoutedPath = nil
            sceneGraph.helmetStraightPath = nil
            return
        }

        let routeGrid = asset.terrain
        let grid = asset.detailedTerrain ?? routeGrid
        if isPlanningVolume {
            sceneGraph.tableRoutedPath = makeRouteRibbon(
                points: TerrainRouteGeometry.densify(comparison.routed.path, source: routeGrid, display: grid),
                sourceGrid: grid, displayGrid: grid, width: 0.88, depth: 0.88,
                ribbonWidth: 0.004, lift: 0.0025, heightScale: 0.00043, clipRadius: 0.44,
                color: .systemGreen, dashed: false, name: "tabletop-planned-route")
            sceneGraph.tableStraightPath = makeRouteRibbon(
                points: TerrainRouteGeometry.densify(comparison.straightLinePath, source: routeGrid, display: grid),
                sourceGrid: grid, displayGrid: grid, width: 0.88, depth: 0.88,
                ribbonWidth: 0.003, lift: 0.0035, heightScale: 0.00043, clipRadius: 0.44,
                color: .systemRed, dashed: true, name: "tabletop-direct-route")
            if let route = sceneGraph.tableRoutedPath { sceneGraph.tableRoot.addChild(route) }
            if let route = sceneGraph.tableStraightPath { sceneGraph.tableRoot.addChild(route) }
            return
        }
        let width = Float(Double(grid.width - 1) * grid.cellSizeMeters)
        let depth = Float(Double(grid.height - 1) * grid.cellSizeMeters)
        let destination = resample(comparison.destination, from: routeGrid, to: grid)
        let droneDestination = makeBeacon(name: "drone-route-destination", color: .systemOrange, radius: 4,
            at: terrainPosition(destination, grid: grid, width: width, depth: depth, lift: 5))
        sceneGraph.droneRoot.addChild(droneDestination)
        let helmetDestination = makeBeacon(name: "helmet-route-destination", color: .systemOrange, radius: 0.35,
            at: terrainPosition(destination, grid: grid, width: width, depth: depth, lift: 1.5))
        sceneGraph.helmetRoot.addChild(helmetDestination)
        sceneGraph.droneRoutedPath = makeRouteRibbon(
            points: comparison.routed.path,
            sourceGrid: routeGrid,
            displayGrid: grid,
            width: width,
            depth: depth,
            ribbonWidth: 3.0,
            color: .systemGreen,
            dashed: false,
            name: "weighted-safe-route"
        )
        sceneGraph.droneStraightPath = makeRouteRibbon(
            points: comparison.straightLinePath,
            sourceGrid: routeGrid,
            displayGrid: grid,
            width: width,
            depth: depth,
            ribbonWidth: 2.2,
            color: .systemRed,
            dashed: true,
            name: "direct-route-comparison"
        )
        if let route = sceneGraph.droneRoutedPath { sceneGraph.droneRoot.addChild(route) }
        if let route = sceneGraph.droneStraightPath { sceneGraph.droneRoot.addChild(route) }
        sceneGraph.helmetRoutedPath = makeRouteRibbon(
            points: comparison.routed.path,
            sourceGrid: routeGrid,
            displayGrid: grid,
            width: width,
            depth: depth,
            ribbonWidth: 0.15,
            lift: 0.07,
            color: .systemGreen,
            dashed: false,
            name: "helmet-weighted-safe-route"
        )
        sceneGraph.helmetStraightPath = makeRouteRibbon(
            points: comparison.straightLinePath,
            sourceGrid: routeGrid,
            displayGrid: grid,
            width: width,
            depth: depth,
            ribbonWidth: 0.09,
            lift: 0.07,
            color: .systemRed,
            dashed: true,
            name: "helmet-direct-route-comparison"
        )
        if let route = sceneGraph.helmetRoutedPath { sceneGraph.helmetRoot.addChild(route) }
        if let route = sceneGraph.helmetStraightPath { sceneGraph.helmetRoot.addChild(route) }
    }

    private func makeRouteRibbon(
        points: [GridPoint],
        sourceGrid: TerrainGrid,
        displayGrid: TerrainGrid,
        width: Float,
        depth: Float,
        ribbonWidth: Float,
        lift: Float = 0.13,
        heightScale: Float = 1,
        clipRadius: Float? = nil,
        color: UIColor,
        dashed: Bool,
        name: String
    ) -> ModelEntity? {
        guard points.count > 1 else { return nil }
        let strideSize = max(1, points.count / 300)
        var sampled = points.enumerated().compactMap { index, point in
            index % strideSize == 0 ? point : nil
        }
        if sampled.last != points.last, let last = points.last { sampled.append(last) }

        let positions = sampled.map { point -> SIMD3<Float> in
            let displayPoint = resample(point, from: sourceGrid, to: displayGrid)
            return TerrainRouteGeometry.position(displayPoint, grid: displayGrid, width: width, depth: depth, heightScale: heightScale, lift: lift)
        }

        var vertices: [SIMD3<Float>] = []
        var indices: [UInt32] = []
        for index in 0..<(positions.count - 1) where !dashed || index % 3 != 1 {
            var start = positions[index]
            var end = positions[index + 1]
            if let radius = clipRadius {
                guard let clipped = TerrainRouteGeometry.clippedSegment(from: start, to: end, radius: radius - ribbonWidth * 0.5) else { continue }
                start = clipped.0
                end = clipped.1
            }
            let delta = end - start
            let horizontal = SIMD3<Float>(delta.x, 0, delta.z)
            let length = simd_length(horizontal)
            guard length > 0.001 else { continue }

            let side = simd_normalize(SIMD3<Float>(-horizontal.z, 0, horizontal.x)) * (ribbonWidth * 0.5)
            let base = UInt32(vertices.count)
            vertices.append(contentsOf: [start + side, start - side, end + side, end - side])
            indices.append(contentsOf: [base, base + 2, base + 1, base + 1, base + 2, base + 3])
        }
        guard !indices.isEmpty else { return nil }

        var descriptor = MeshDescriptor(name: name)
        descriptor.positions = MeshBuffers.Positions(vertices)
        descriptor.normals = MeshBuffers.Normals(Array(repeating: SIMD3<Float>(0, 1, 0), count: vertices.count))
        descriptor.primitives = .triangles(indices)
        descriptor.materials = .allFaces(0)
        guard let mesh = try? MeshResource.generate(from: [descriptor]) else { return nil }
        let entity = ModelEntity(mesh: mesh, materials: [UnlitMaterial(color: color)])
        entity.name = name
        return entity
    }

    @MainActor
    private func buildTableHazards(grid: TerrainGrid) {
        sceneGraph.tableHazardsRoot.name = "synthetic-terrain-class-overlays"
        let obstacles: [(Int, Int, Float)] = [
            (46, 56, 0.018), (50, 58, 0.024), (54, 56, 0.016), (47, 63, 0.022),
            (52, 65, 0.018), (55, 70, 0.025), (49, 72, 0.019), (44, 69, 0.014)
        ]
        for (index, obstacle) in obstacles.enumerated() {
            let rock = ModelEntity(
                mesh: .generateSphere(radius: obstacle.2),
                materials: [SimpleMaterial(color: UIColor(white: 0.16, alpha: 1), roughness: 0.98, isMetallic: false)]
            )
            rock.name = "synthetic-obstacle-\(index)"
            rock.position = mapPosition(GridPoint(x: obstacle.0, y: obstacle.1), grid: grid, lift: obstacle.2)
            sceneGraph.tableHazardsRoot.addChild(rock)
        }
        sceneGraph.tableRoot.addChild(sceneGraph.tableHazardsRoot)
    }

    @MainActor
    private func handleTap(on entity: Entity, at localLocation: Point3D) {
        if entity.name.hasPrefix("crew-") {
            missionStore.selectCrew(entity.name)
        } else if entity.name.hasPrefix("landmark:") {
            missionStore.selectLandmark(entity.name.replacingOccurrences(of: "landmark:", with: ""))
        }
    }

    private func exitMission() {
        missionStore.immersiveSpaceState = .inTransition
        Task { @MainActor in
            await dismissImmersiveSpace()
            missionStore.immersiveSpaceState = .closed
        }
    }

    private func makeBeacon(name: String, color: UIColor, radius: Float, at position: SIMD3<Float>) -> ModelEntity {
        let marker = ModelEntity(mesh: .generateSphere(radius: radius), materials: [UnlitMaterial(color: color)])
        marker.name = name
        marker.position = position
        marker.components.set(InputTargetComponent())
        marker.components.set(CollisionComponent(shapes: [.generateSphere(radius: radius * 2.7)]))
        marker.components.set(HoverEffectComponent())

        let halo = ModelEntity(
            mesh: .generateSphere(radius: radius * 1.45),
            materials: [SimpleMaterial(color: color.withAlphaComponent(0.22), roughness: 1, isMetallic: false)]
        )
        halo.name = "\(name)-beacon-halo"
        marker.addChild(halo)
        return marker
    }

    private func makeGlobeBeacon(
        name: String,
        color: UIColor,
        radius: Float,
        markerID: String,
        surfacePosition: SIMD3<Float>
    ) -> ModelEntity {
        let markerPosition = GlobePinLayout.beaconPosition(markerID: markerID, surfacePosition: surfacePosition)
        // A bright core and a colored, outward-facing disc remain legible against
        // both light and dark terrain; the collision target is larger than the icon.
        let marker = ModelEntity(mesh: .generateSphere(radius: radius * 0.55), materials: [UnlitMaterial(color: .white)])
        marker.name = name
        marker.position = markerPosition
        marker.components.set(InputTargetComponent())
        marker.components.set(HoverEffectComponent())
        let disc = ModelEntity(mesh: .generateCylinder(height: 0.0015, radius: radius * 1.45), materials: [UnlitMaterial(color: color)])
        disc.orientation = simd_quatf(from: SIMD3<Float>(0, 1, 0), to: simd_normalize(markerPosition))
        disc.position = -simd_normalize(markerPosition) * 0.001
        marker.addChild(disc)
        var haloMaterial = UnlitMaterial(color: color)
        haloMaterial.blending = .transparent(opacity: 0.23)
        let halo = ModelEntity(mesh: .generateCylinder(height: 0.0006, radius: radius * 2), materials: [haloMaterial])
        halo.orientation = disc.orientation
        halo.position = -simd_normalize(markerPosition) * 0.002
        marker.addChild(halo)
        // Keep neighboring Gale hit targets distinct.
        marker.components.set(CollisionComponent(shapes: [.generateSphere(radius: GlobePinLayout.hitRadiusMeters)]))

        let leaderVector = surfacePosition - markerPosition
        let leaderLength = simd_length(leaderVector)
        if leaderLength > 0.0001 {
            let leader = ModelEntity(
                mesh: .generateCylinder(height: leaderLength, radius: 0.0008),
                materials: [UnlitMaterial(color: color)]
            )
            leader.name = "\(name)-surface-leader"
            leader.position = leaderVector * 0.5
            leader.orientation = simd_quatf(
                from: SIMD3<Float>(0, 1, 0),
                to: simd_normalize(leaderVector)
            )
            marker.addChild(leader)
        }
        return marker
    }

    private func globePosition(for coordinate: PlanetCoordinate, radius: Float) -> SIMD3<Float> {
        GlobeCoordinates.normal(
            latitudeDegrees: Float(coordinate.latitudeDegrees),
            longitudeDegreesEast: Float(coordinate.longitudeDegreesEast)
        ) * radius
    }

    private func approximateCoordinate(for point: GridPoint) -> PlanetCoordinate {
        guard let grid = missionStore.terrainAsset?.terrain,
              let metadata = missionStore.terrainAsset?.metadata else {
            return PlanetCoordinate(latitudeDegrees: -4.7, longitudeDegreesEast: 137.3)
        }
        let eastMeters = Double(point.x - grid.width / 2) * grid.cellSizeMeters
        let northMeters = Double(grid.height / 2 - point.y) * grid.cellSizeMeters
        let latitude = metadata.sourceLocation.latitudeCenterDegrees + northMeters / 111_195
        let longitudeScale = 111_195 * cos(metadata.sourceLocation.latitudeCenterDegrees * .pi / 180)
        return PlanetCoordinate(
            latitudeDegrees: latitude,
            longitudeDegreesEast: metadata.sourceLocation.longitudeCenterDegreesEast + eastMeters / longitudeScale
        )
    }

    private func mapPosition(
        _ point: GridPoint,
        grid: TerrainGrid,
        width: Float = 0.88,
        depth: Float = 0.88,
        lift: Float
    ) -> SIMD3<Float> {
        let x = Float(point.x) / Float(grid.width - 1) * width - width / 2
        let z = Float(point.y) / Float(grid.height - 1) * depth - depth / 2
        let elevation = Float(grid.relativeElevation(at: point)) * 0.00043
        return SIMD3<Float>(x, elevation + lift, z)
    }

    private func attachmentScale(_ attachment: ViewAttachmentEntity, targetWidth: Float) -> SIMD3<Float> {
        let measuredWidth = attachment.attachment.bounds.extents.x
        guard measuredWidth > 0 else { return SIMD3<Float>(repeating: 1) }
        return SIMD3<Float>(repeating: targetWidth / measuredWidth)
    }

    private func terrainPosition(_ point: GridPoint, grid: TerrainGrid, width: Float, depth: Float, lift: Float) -> SIMD3<Float> {
        let x = Float(point.x) / Float(grid.width - 1) * width - width / 2
        let z = Float(point.y) / Float(grid.height - 1) * depth - depth / 2
        return SIMD3<Float>(x, Float(grid.relativeElevation(at: point)) + lift, z)
    }

    private func terrainMaterial(color: UIColor, roughness: Float) -> PhysicallyBasedMaterial {
        var material = PhysicallyBasedMaterial()
        material.baseColor = .init(tint: color)
        material.roughness = .init(scale: roughness)
        material.metallic = 0.0
        return material
    }

    private func resample(_ point: GridPoint, from source: TerrainGrid, to target: TerrainGrid) -> GridPoint {
        guard source.width > 1, source.height > 1 else { return GridPoint(x: 0, y: 0) }
        return GridPoint(
            x: Int((Double(point.x) / Double(source.width - 1) * Double(target.width - 1)).rounded()),
            y: Int((Double(point.y) / Double(source.height - 1) * Double(target.height - 1)).rounded())
        )
    }

    private func addBox(size: SIMD3<Float>, position: SIMD3<Float>, color: UIColor, name: String, to root: Entity) {
        let model = ModelEntity(mesh: .generateBox(size: size), materials: [SimpleMaterial(color: color, roughness: 0.75, isMetallic: false)])
        model.name = name
        model.position = position
        root.addChild(model)
    }

    private func addFallbackTerrain(to root: Entity) {
        let surface = ModelEntity(
            mesh: .generateBox(size: SIMD3<Float>(24, 0.15, 24)),
            materials: [SimpleMaterial(color: UIColor(red: 0.45, green: 0.22, blue: 0.14, alpha: 1), roughness: 0.95, isMetallic: false)]
        )
        surface.position = SIMD3<Float>(0, -2, 0)
        root.addChild(surface)
    }

}

@MainActor
private final class ImmersiveSceneGraph {
    // The helmet visor HUD is the only user-facing attachment intentionally tied to view direction.
    let controlsAnchor = AnchorEntity(.head)
    let globeAnchor = AnchorEntity(world: .zero)
    let trackingSession = ARKitSession()
    let worldTracking = WorldTrackingProvider()
    var viewerPosition = SIMD3<Float>(0, 1.55, 0)
    var viewerForward = SIMD3<Float>(0, 0, -1)
    var stageEntryForward = SIMD3<Float>(0, 0, -1)
    var hasTrackedViewer = false
    var stageEntryEye = SIMD3<Float>(0, 1.55, 0)
    var globePlaced = false
    let droneAnchor = AnchorEntity(world: .zero)
    let helmetAnchor = AnchorEntity(world: .zero)
    let habitatAnchor = AnchorEntity(world: SIMD3<Float>(0, 1.5, -0.6))
    let globeRoot = Entity()
    let tableRoot = Entity()
    var tableTargetTransform = Transform(scale: .one, rotation: simd_quatf(angle: 0, axis: SIMD3<Float>(1, 0, 0)), translation: SIMD3<Float>(0, -0.24, 0.13))
    let dockRoot = Entity()
    let tableHazardsRoot = Entity()
    var dustEffect: Entity?
    var dustReduceMotion = false
    let droneRoot = Entity()
    let helmetRoot = Entity()
    let droneSkyRoot = Entity()
    let helmetSkyRoot = Entity()
    let habitatRoot = Entity()
    let alertAudioEntity = Entity()
    var marsSkyAssets: MarsSkyAssets?
    var globeSunLight: Entity?

    var tableAnchor: AnchorEntity
    var controlsEntity: ViewAttachmentEntity?
    var globeCrewMarkers: [String: ModelEntity] = [:]
    var globeLandmarkMarkers: [String: ModelEntity] = [:]
    var globeLabelIDs: Set<String> = []
    var globeMaterials: [MissionLayer: PhysicallyBasedMaterial] = [:]
    var galeSurfaceMaterial: PhysicallyBasedMaterial?
    var sharedImmersiveTerrainMesh: MeshResource?
    var sharedHorizonMesh: MeshResource?
    var droneHorizonEntity: ModelEntity?
    var helmetHorizonEntity: ModelEntity?
    var nativeDetailCenter: GridPoint?
    var desiredDetailCenter: GridPoint?
    var nativeDetailTask: Task<Void, Never>?
    var terrainBuildTask: Task<Void, Never>?
    var tableTerrainEntity: ModelEntity?
    var tableOpticalMaterial: UnlitMaterial?
    var droneTerrainEntity: ModelEntity?
    var helmetTerrainEntity: ModelEntity?
    var lastLocalOpticalVisibility: Bool?
    var tableSlopeOverlay: ModelEntity?
    var tableCrewMarkers: [String: ModelEntity] = [:]
    var tableLandmarkMarkers: [String: ModelEntity] = [:]
    var droneCrewMarkers: [String: ModelEntity] = [:]
    var habitatCrewMarkers: [String: ModelEntity] = [:]
    var habitatMissionMarkers: [String: ModelEntity] = [:]
    var helmetCrewMarkers: [String: ModelEntity] = [:]
    var tableRoutedPath: ModelEntity?
    var tableStraightPath: ModelEntity?
    var droneRoutedPath: ModelEntity?
    var droneStraightPath: ModelEntity?
    var helmetRoutedPath: ModelEntity?
    var helmetStraightPath: ModelEntity?
    var droneSlopeOverlay: ModelEntity?
    var helmetSlopeOverlay: ModelEntity?
    var globeModel: ModelEntity?
    var skyMaterial: UnlitMaterial?
    var renderedStage: MissionStage?
    var cardOwner: String?
    var landmarkCardOwner: String?
    var layerOverlayEntity: ViewAttachmentEntity?
    var habitatMapOverlayEntity: ViewAttachmentEntity?
    var helmetHUD: ViewAttachmentEntity?
    var alertEntity: ViewAttachmentEntity?
    var radioCommsEntity: ViewAttachmentEntity?
    var evaDrawerEntity: ViewAttachmentEntity?
    var lastRenderedRoute: RouteComparison?
    var lastInspectionOffset: GridPoint?
    var lastAerialZoom: Double?
    var lastAerialRoute: RouteComparison?
    var lastHelmetWaypoint: GridPoint?
    var lastHelmetPlaybackState: Bool?
    var transitionTask: Task<Void, Never>?
    var habitatLoadStarted = false
    var habitatLoaded = false
    var habitatMapBuilt = false
    var lastPlayedAlert: MissionAlert?
    var hasStartedBuildingScene = false

    init() {
        globeAnchor.position = SIMD3<Float>(0, 1.45, -1.2)
        #if targetEnvironment(simulator)
        tableAnchor = AnchorEntity(world: SIMD3<Float>(0, 0.76, -1.05))
        #else
        tableAnchor = AnchorEntity(.plane(
            .horizontal,
            classification: .table,
            minimumBounds: SIMD2<Float>(0.5, 0.5)
        ))
        #endif
    }
}

private struct GlobeLandmarkButton: View {
    let landmark: MissionLandmark
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Circle()
                .fill(landmark.isScenarioOnly ? Color.orange : Color.white)
                .frame(width: 32, height: 32)
                .overlay(Circle().stroke(.black.opacity(0.65), lineWidth: 3))
                .overlay(alignment: .leading) {
                    Text(landmark.name)
                        .font(.system(size: 22, weight: .semibold))
                        .lineLimit(1)
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .glassBackgroundEffect(in: Capsule())
                        .fixedSize()
                        .offset(x: 0, y: -44)
                        .allowsHitTesting(false)
                        .hoverEffect { effect, active, _ in
                            effect.animation(.easeInOut(duration: 0.2).delay(active ? 0.3 : 0.8)) {
                                $0.opacity(active ? 1 : 0)
                            }
                        }
                }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .hoverEffectGroup()
        .accessibilityLabel(landmark.name)
    }
}

private struct CrewInfoCard: View {
    let telemetry: CrewTelemetry
    let emergency: EmergencyDemoState?
    let transmit: () -> Void
    let close: () -> Void
    @State private var showsVitals = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Circle()
                .fill(telemetry.radioLineOfSight ? Color.green : Color.orange)
                .frame(width: 10, height: 10)
                .padding(.top, 4)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(telemetry.callsign)
                        .font(.headline)
                    Text("SIMULATED")
                        .font(.system(size: 8, weight: .bold, design: .rounded))
                        .foregroundStyle(.orange)
                }
                if let emergency {
                    if let reserve = emergency.remainingReservePercent {
                        Text("Return reserve \(Int(reserve.rounded()))% · \(emergency.limitingResource ?? "resource") limiting")
                    } else {
                        Text("No demo return route found")
                    }
                    Text("Modeled starting resources: 75%")
                        .font(.caption2).foregroundStyle(.secondary)
                } else {
                    Text("O₂ \(Int(telemetry.oxygenPercent))% · Walk-back \(Int(telemetry.walkBackMarginPercent))%")
                }
                Button(showsVitals ? "Hide vitals" : "Show vitals", systemImage: "heart.text.square") { showsVitals.toggle() }
                    .font(.caption2.weight(.semibold)).buttonStyle(.plain)
                if showsVitals {
                    Text(emergency == nil ? "O₂ \(Int(telemetry.oxygenPercent))% · Cooling \(telemetry.coolingWaterKilograms, specifier: "%.1f") kg" : "O₂ and cooling start at 75% of demo capacity")
                    Text("Metabolic \(Int(telemetry.metabolicWatts)) W · Dose \(telemetry.radiationDoseMicroSieverts, specifier: "%.1f") µSv")
                    Text("Radio \(telemetry.radioLineOfSight ? "clear" : "shadow") · \(telemetry.terrainClass.rawValue)")
                    Text("Scenario readings · not live telemetry")
                        .foregroundStyle(.secondary)
                    Button(action: transmit) { Label("Radio check", systemImage: "waveform") }
                        .buttonStyle(.plain)
                }
            }
            Spacer(minLength: 4)
            Button(action: close) {
                Image(systemName: "xmark")
                    .font(.caption.weight(.bold))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss crew card")
        }
        .padding(13)
        .font(.caption2.monospacedDigit())
        .frame(width: 290)
        .glassBackgroundEffect(in: RoundedRectangle(cornerRadius: 16))
    }
}

private struct RadioCommsPill: View {
    let transmission: RadioTransmission
    let opacity: Double

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "waveform")
                .symbolEffect(.variableColor.iterative, isActive: opacity > 0.7)
                .foregroundStyle(.green)
            VStack(alignment: .leading, spacing: 1) {
                Text("UHF · \(transmission.callsign)")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                Text(transmission.transcript)
                    .font(.system(size: 9, weight: .regular))
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 7)
        .glassBackgroundEffect(in: Capsule())
        .overlay(Capsule().stroke(.white.opacity(0.18), lineWidth: 1))
        .opacity(opacity)
        .accessibilityLabel("Remote simulated Mars UHF transmission from \(transmission.callsign): \(transmission.transcript)")
    }
}

private struct ActiveEVADrawer: View {
    let missionStore: MissionStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("EVAs").font(.headline)
                Spacer()
                Button { missionStore.isEVADrawerVisible = false } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Close EVA drawer")
            }
            Text("LIVE · SIMULATED")
                .font(.system(size: 9, weight: .bold, design: .rounded))
                .foregroundStyle(.green)
            evaRow("EVA-01 · Altadena science stop", icon: "figure.walk", crewID: "crew-01")
            evaRow("EVA-02 · Support", icon: "figure.walk", crewID: "crew-02")
            Divider()
            Text("PLANNED").font(.system(size: 9, weight: .bold, design: .rounded)).foregroundStyle(.secondary)
            Button { openMission() } label: { Label("EVA-03 · Gale traverse [DEMO]", systemImage: "calendar") }
                .buttonStyle(.plain)
            Divider()
            Text("PAST").font(.system(size: 9, weight: .bold, design: .rounded)).foregroundStyle(.secondary)
            Button {
                missionStore.scrubPlayback(to: 1)
                openMission()
            } label: { Label("Altadena route playback", systemImage: "clock.arrow.circlepath") }
                .buttonStyle(.plain)
        }
        .font(.caption)
        .padding(13)
        .frame(width: 280)
        .glassBackgroundEffect(in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func evaRow(_ title: String, icon: String, crewID: String) -> some View {
        Button {
            missionStore.selectCrew(crewID)
            missionStore.selectLandmark("altadena-boxwork")
            missionStore.setStage(.tabletop)
            missionStore.isEVADrawerVisible = false
        } label: {
            Label(title, systemImage: icon)
                .lineLimit(2)
        }
        .buttonStyle(.plain)
    }

    private func openMission() {
        missionStore.selectLandmark("altadena-boxwork")
        missionStore.setStage(.tabletop)
        missionStore.isEVADrawerVisible = false
    }
}

private struct LandmarkInfoCard: View {
    let landmark: MissionLandmark
    let isTerrainReady: Bool
    let terrainUnavailable: Bool
    let close: () -> Void
    let explore: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(landmark.name).font(.headline)
                    Text(landmark.isScenarioOnly
                         ? "DEMO SCENARIO"
                         : (landmark.id == "jezero-crater" ? "GLOBE MARKER · NO LOCAL TERRAIN" : "GALE REGIONAL CONTEXT"))
                        .font(.system(size: 8, weight: .bold, design: .rounded))
                        .foregroundStyle(landmark.isScenarioOnly ? .orange : .secondary)
                }
                Spacer(minLength: 4)
                Button(action: close) { Image(systemName: "xmark") }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Close landmark details")
            }
            Text(landmark.detail)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if landmark.id == "jezero-crater" {
                Text("Jezero is a globe-only marker in this build; detailed terrain is available for Gale.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Button(action: explore) {
                    Label(isTerrainReady ? "Open Gale sector" : (terrainUnavailable ? "Gale terrain unavailable" : "Loading Gale terrain…"), systemImage: "arrow.down.right.and.arrow.up.left")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
                .disabled(!isTerrainReady)
            }
        }
        .padding(13)
        .frame(width: 290)
        .glassBackgroundEffect(in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

private struct HelmetVisorHUD: View {
    let missionStore: MissionStore

    private var telemetry: CrewTelemetry? { missionStore.crewTelemetry.first }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("EVA VISOR · SIMULATED")
                .font(.system(size: 8, weight: .bold, design: .rounded))
                .tracking(0.8)
            if let demo = missionStore.emergencyDemo {
                if let reserve = demo.remainingReservePercent {
                    Text("Return reserve \(Int(reserve.rounded()))% · \(demo.limitingResource ?? "resource") limiting")
                        .font(.caption.monospacedDigit().weight(.semibold))
                } else {
                    Text("No demo return route found")
                        .font(.caption.weight(.semibold))
                }
                Text("Airlock [DEMO] \(waypointDistance) m · \(waypointBearing)°")
                    .font(.caption2.monospacedDigit())
            } else if let telemetry {
                Text("O₂ \(Int(telemetry.oxygenPercent))%  ·  Walk-back \(Int(telemetry.walkBackMarginPercent))%")
                    .font(.caption.monospacedDigit().weight(.semibold))
                Text("Waypoint \(waypointDistance) m · \(waypointBearing)°")
                    .font(.caption2.monospacedDigit())
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .glassBackgroundEffect(in: Capsule())
    }

    private var waypointDistance: Int {
        guard let grid = missionStore.terrainAsset?.terrain,
              let telemetry else { return 0 }
        let target = missionStore.emergencyDemo?.returnRoute?.destination ?? missionStore.helmetWaypoint
        let origin = missionStore.emergencyDemo == nil ? telemetry.point : missionStore.helmetWaypoint
        let dx = Double(target.x - origin.x)
        let dy = Double(target.y - origin.y)
        return Int((hypot(dx, dy) * grid.cellSizeMeters).rounded())
    }

    private var waypointBearing: Int {
        guard let telemetry else { return 0 }
        let target = missionStore.emergencyDemo?.returnRoute?.destination ?? missionStore.helmetWaypoint
        let origin = missionStore.emergencyDemo == nil ? telemetry.point : missionStore.helmetWaypoint
        let bearing = atan2(Double(target.x - origin.x), Double(origin.y - target.y)) * 180 / .pi
        return (Int(bearing.rounded()) + 360) % 360
    }
}

private struct EmergencyAlertCard: View {
    let alert: MissionAlert

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
            VStack(alignment: .leading, spacing: 2) {
                Text(alert.title).font(.caption.weight(.bold))
                Text(alert.detail).font(.caption2)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(.red.opacity(0.92), in: Capsule())
        .overlay(Capsule().stroke(.white.opacity(0.75), lineWidth: 1))
        .shadow(color: .red.opacity(0.45), radius: 12)
    }
}
