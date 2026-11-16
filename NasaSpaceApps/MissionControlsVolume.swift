import SwiftUI
import GroupActivities

/// A movable system volume shared by all mission stages.
struct MissionControlsVolume: View {
    @Environment(MissionStore.self) private var missionStore
    @Environment(GroupSessionCoordinator.self) private var sharePlayCoordinator
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace
    @Environment(\.openWindow) private var openWindow
    @State private var showsLayers = false
    @State private var showsRouteDetails = false
    @State private var showsSources = false
    @State private var explanationService = EmergencyExplanationService()
    @State private var explanation: EmergencyExplanation?
    @State private var isExplaining = false
    @State private var demoGeneration = 0
    @State private var volumeImmersionStyle: any ImmersionStyle = .mixed

    var body: some View {
        ImmersiveView(isPlanningVolume: true, immersionStyle: $volumeImmersionStyle)
        .ornament(attachmentAnchor: .scene(.bottom)) {
            VStack(alignment: .leading, spacing: 10) {
                if let error = missionStore.currentTerrainLoadError {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.caption).padding(8)
                        .glassBackgroundEffect(in: Capsule())
                } else if !missionStore.isReady(for: missionStore.stage == .globe ? .tabletop : missionStore.stage) {
                    Label("Loading Gale terrain…", systemImage: "mountain.2")
                        .font(.caption).padding(8)
                        .glassBackgroundEffect(in: Capsule())
                }
                if missionStore.emergencyDemo != nil, missionStore.stage != .globe {
                    Label(hasDemoRoute ? "Simulated dust · return route" : "Simulated dust · no return found", systemImage: "exclamationmark.triangle")
                        .font(.caption).padding(8).glassBackgroundEffect(in: Capsule())
                } else if missionStore.stage == .tabletop {
                    Label(hasDemoRoute ? "Demo route ready" : "No demo route found", systemImage: hasDemoRoute ? "checkmark.circle" : "exclamationmark.triangle")
                        .font(.caption).padding(8).glassBackgroundEffect(in: Capsule())
                }
                if showsLayers {
                    layerControls
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
                if showsRouteDetails, missionStore.stage != .globe {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(missionStore.emergencyDemo == nil ? "Route comparison · scenario" : "Emergency return · simulated").font(.caption.weight(.semibold))
                        if let comparison = missionStore.routeComparison {
                            if let failure = comparison.failureReason {
                                Text(failure.message).font(.caption2)
                                Text("Direct line: \(Int(comparison.straightLineDistanceMeters.rounded())) m").font(.caption2)
                            } else {
                                Text("Green route: \(Int(comparison.routed.distanceMeters.rounded())) m · Red direct: \(Int(comparison.straightLineDistanceMeters.rounded())) m").font(.caption2)
                                if let demo = missionStore.emergencyDemo, let reserve = demo.remainingReservePercent {
                                    Text("\(Int(comparison.routed.traverseMinutes.rounded())) min return · \(Int(reserve.rounded()))% modeled reserve · \(demo.limitingResource ?? "resource") limiting").font(.caption2)
                                    Text("Simulated crew starts with 75% of each demo resource.").font(.caption2)
                                } else {
                                    Text("\(Int(comparison.routed.traverseMinutes.rounded())) min one way · \(Int(comparison.routed.walkBackMarginPercent.rounded()))% modeled reserve").font(.caption2)
                                }
                                if let warning = comparison.routed.warning { Text(warning).font(.caption2) }
                            }
                        } else {
                            Text("Choose distinct points on the Gale map.").font(.caption2)
                        }
                        if let explanation {
                            Text(explanation.isModelGenerated ? "Apple Intelligence + planner values" : "Planner explanation · scripted fallback").font(.caption2.weight(.semibold))
                            Text(explanation.text).font(.caption2)
                            Button("Speak explanation", systemImage: "speaker.wave.2") { explanationService.speak(explanation.text) }.font(.caption2)
                        }
                        Text("Shelter availability not modeled · suit and terrain classes simulated").font(.caption2).foregroundStyle(.secondary)
                        Text("Gale HiRISE context · Altadena overlap unverified").font(.caption2).foregroundStyle(.secondary)
                        Button(showsSources ? "Hide sources" : "Sources and coverage", systemImage: "info.circle") {
                            withAnimation(.easeInOut(duration: 0.2)) { showsSources.toggle() }
                        }.font(.caption2)
                        if showsSources {
                            Group {
                                Text("Local: MRO HiRISE registered RED imagery and elevation; slope is calculated from the DTM.")
                                Text("Globe: Viking and MOLA are global context; THEMIS infrared has incomplete polar coverage.")
                                Text("Distant terrain, Airlock Alpha, crew, dust and suit resources are simulated. Altadena overlap is unverified.")
                            }.font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    .padding(12).glassBackgroundEffect(in: RoundedRectangle(cornerRadius: 16))
                    .transition(.opacity)
                }
                HStack(spacing: 8) {
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) { showsLayers.toggle() }
                    } label: {
                        Label("Layers", systemImage: "square.3.layers.3d")
                            .padding(.horizontal, 14).padding(.vertical, 9)
                            .background(showsLayers ? Color.orange.opacity(0.8) : Color.black.opacity(0.45), in: Capsule())
                    }

                    if missionStore.stage == .globe {
                        Button {
                            Task { _ = try? await MissionShareActivity().activate() }
                        } label: {
                            Label(sharePlayCoordinator.isActive ? "\(sharePlayCoordinator.participantCount)" : "SharePlay", systemImage: "shareplay")
                                .padding(.horizontal, 14).padding(.vertical, 9)
                                .background(Color.black.opacity(0.45), in: Capsule())
                        }
                        .accessibilityLabel(missionStore.sessionStatus)
                    }

                    if missionStore.stage == .globe || missionStore.stage == .tabletop {
                        Button {
                            if missionStore.isCrewCardVisible { missionStore.dismissCrewCard() }
                            else { missionStore.selectCrew("crew-01") }
                        } label: {
                            Label("EVA crew", systemImage: "figure.walk")
                                .padding(.horizontal, 14).padding(.vertical, 9)
                                .background(missionStore.isCrewCardVisible ? Color.orange.opacity(0.8) : Color.black.opacity(0.45), in: Capsule())
                        }
                        .accessibilityLabel("Show simulated EVA crew details")
                    }

                    if missionStore.stage == .tabletop {
                        Button {
                            demoGeneration += 1
                            if missionStore.emergencyDemo == nil { missionStore.startEmergencyDemo() }
                            else { missionStore.resetEmergencyDemo(); explanation = nil; explanationService.stopSpeaking() }
                        } label: {
                            Label(missionStore.emergencyDemo == nil ? "Start emergency demo" : "Reset demo", systemImage: missionStore.emergencyDemo == nil ? "wind" : "arrow.counterclockwise")
                                .padding(.horizontal, 14).padding(.vertical, 9)
                                .background(Color.black.opacity(0.45), in: Capsule())
                        }.accessibilityLabel(missionStore.emergencyDemo == nil ? "Start simulated emergency demo" : "Reset emergency demo")
                    }

                    if missionStore.stage == .tabletop || missionStore.stage == .drone || missionStore.stage == .helmet {
                        Button { withAnimation(.easeInOut(duration: 0.2)) { showsRouteDetails.toggle() } } label: {
                            Label("Route", systemImage: "point.topleft.down.curvedto.point.bottomright.up")
                                .padding(.horizontal, 14).padding(.vertical, 9)
                                .background(showsRouteDetails ? Color.orange.opacity(0.8) : Color.black.opacity(0.45), in: Capsule())
                        }
                    }

                    if missionStore.emergencyDemo != nil && missionStore.stage == .tabletop {
                        Button { explainReturn() } label: {
                            Label(isExplaining ? "Explaining…" : "Explain return", systemImage: "sparkles")
                                .padding(.horizontal, 14).padding(.vertical, 9)
                                .background(Color.black.opacity(0.45), in: Capsule())
                        }.disabled(isExplaining)
                    }
                    if missionStore.stage == .drone || missionStore.stage == .helmet {
                        movementButton("arrow.left", label: "Move left", dx: -4, dy: 0)
                        movementButton("arrow.right", label: "Move right", dx: 4, dy: 0)
                        movementButton("arrow.up", label: "Move forward", dx: 0, dy: -4)
                        movementButton("arrow.down", label: "Move back", dx: 0, dy: 4)
                    }
                    if missionStore.stage == .drone {
                        Button { missionStore.zoomAerial(by: 1 / 1.4) } label: { Image(systemName: "minus.magnifyingglass").padding(10).background(Color.black.opacity(0.45), in: Circle()) }.accessibilityLabel("Zoom out")
                        Button { missionStore.zoomAerial(by: 1.4) } label: { Image(systemName: "plus.magnifyingglass").padding(10).background(Color.black.opacity(0.45), in: Circle()) }.accessibilityLabel("Zoom in")
                    }
                    if missionStore.stage != .globe {
                        Button { returnToGlobe() } label: {
                            Image(systemName: "xmark")
                                .padding(10).background(Color.black.opacity(0.45), in: Circle())
                        }
                        .accessibilityLabel("Return to globe")
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white)
                .padding(10)
                .glassBackgroundEffect(in: Capsule())
            }
            .padding(8)
            .offset(z: 220)
        }
        .ornament(attachmentAnchor: .scene(.trailing)) {
            if missionStore.stage != .globe {
            VStack(spacing: 4) {
                stageButton(.globe, icon: "globe.americas.fill", title: "Globe")
                stageButton(.tabletop, icon: "map", title: "Map")
                stageButton(.drone, icon: "view.3d", title: "Drone")
                stageButton(.helmet, icon: "viewfinder", title: "Helmet")
            }
            .padding(8)
            .glassBackgroundEffect(in: RoundedRectangle(cornerRadius: 24))
            .offset(z: 220)
            }
        }
        .task { sharePlayCoordinator.startObserving(store: missionStore) }
    }

    private var layerControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            if missionStore.stage == .globe {
                HStack {
                    globeLayer(.optical, "Optical")
                    globeLayer(.themisInfrared, "THEMIS Day IR")
                }
                HStack {
                    globeLayer(.themisNightInfrared, "THEMIS Night IR")
                    globeLayer(.molaElevation, "MOLA")
                    globeLayer(.globalGeology, "Geology")
                }
                Text(globeLayerSource)
                    .font(.caption2).foregroundStyle(.secondary)
            } else {
                HStack {
                    localLayer(.optical, "HiRISE Optical")
                    localLayer(.slopeTraction, "DTM Slope")
                }
                Text("Gale context · Altadena overlap unverified · distant horizon is synthetic")
                    .font(.caption2).foregroundStyle(.secondary)
                if missionStore.activeLayers.contains(.slopeTraction) {
                    Text("Slope from HiRISE DTM: green <7° · amber 7–14° · red ≥14°. Color thresholds are demo assumptions, not measured traction.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        .padding(12)
        .glassBackgroundEffect(in: RoundedRectangle(cornerRadius: 18))
    }

    private var globeLayerSource: String {
        switch missionStore.selectedGlobeLayer {
        case .optical:
            "NASA Ames / USGS Viking MDIM 2.1 · global color mosaic, 232 m source pixels."
        case .molaElevation:
            "NASA MOLA / USGS · color represents global elevation, approximately 463 m source pixels."
        case .themisInfrared, .themisNightInfrared:
            "NASA THEMIS / USGS · regional infrared mosaic; incomplete polar coverage, not live temperature or firmness."
        case .globalGeology:
            "USGS SIM 3292 · global geologic units, 1:20 million scale; regional context."
        default:
            "Global context; see the data provenance notes for coverage and interpretation."
        }
    }

    private func globeLayer(_ layer: MissionLayer, _ title: String) -> some View {
        Button(title, systemImage: missionStore.selectedGlobeLayer == layer ? "checkmark.circle.fill" : "circle") {
            missionStore.selectGlobeLayer(layer)
        }
        .buttonStyle(.plain)
        .padding(8)
        .foregroundStyle(.white)
        .background(missionStore.selectedGlobeLayer == layer ? Color.orange.opacity(0.8) : Color.black.opacity(0.45), in: Capsule())
    }

    private func localLayer(_ layer: MissionLayer, _ title: String) -> some View {
        Button(title, systemImage: missionStore.activeLayers.contains(layer) ? "checkmark.circle.fill" : "circle") {
            missionStore.toggleLayer(layer)
        }
        .buttonStyle(.plain)
        .padding(8)
        .foregroundStyle(.white)
        .background(missionStore.activeLayers.contains(layer) ? Color.orange.opacity(0.8) : Color.black.opacity(0.45), in: Capsule())
    }

    private func explainReturn() {
        guard let demo = missionStore.emergencyDemo else { return }
        let comparison = demo.returnRoute
        let valid = comparison?.failureReason == nil && !(comparison?.routed.path.isEmpty ?? true)
        let input = EmergencyExplanationInput(routeFound: valid,
            distanceMeters: comparison?.routed.distanceMeters ?? 0,
            durationMinutes: comparison?.routed.traverseMinutes ?? 0,
            reservePercent: demo.remainingReservePercent ?? 0,
            limitingResource: demo.limitingResource ?? "unavailable",
            warning: comparison?.failureReason?.message ?? comparison?.routed.warning)
        let generation = demoGeneration
        isExplaining = true
        showsRouteDetails = true
        Task { @MainActor in
            let result = await explanationService.explain(input)
            if missionStore.emergencyDemo != nil && demoGeneration == generation { explanation = result }
            isExplaining = false
        }
    }

    private var hasDemoRoute: Bool {
        guard let comparison = missionStore.routeComparison else { return false }
        return comparison.failureReason == nil && !comparison.routed.path.isEmpty
    }

    private func stageButton(_ stage: MissionStage, icon: String, title: String) -> some View {
        Button {
            if stage != .globe && !missionStore.hasGaleTerrainContext {
                missionStore.selectLandmark("mount-sharp-boxwork")
                missionStore.isLandmarkCardVisible = false
            }
            missionStore.setStage(stage)
        } label: {
            Label(title, systemImage: icon)
                .frame(width: 94, alignment: .leading)
                .padding(.horizontal, 10).padding(.vertical, 8)
                .foregroundStyle(.white)
                .background(missionStore.stage == stage ? Color.orange.opacity(0.85) : Color.black.opacity(0.45), in: Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!missionStore.isReady(for: stage))
        .accessibilityAddTraits(missionStore.stage == stage ? .isSelected : [])
    }

    private func movementButton(_ symbol: String, label: String, dx: Int, dy: Int) -> some View {
        Button {
            if missionStore.stage == .helmet { missionStore.moveHelmetWaypoint(dx: dx, dy: dy) }
            else { missionStore.moveInspection(dx: dx, dy: dy) }
        } label: {
            Image(systemName: symbol)
                .padding(10).background(Color.black.opacity(0.45), in: Circle())
        }
        .accessibilityLabel(label)
    }

    private func returnToGlobe() {
        missionStore.isLandmarkCardVisible = false
        missionStore.isCrewCardVisible = false
        missionStore.isEVADrawerVisible = false
        missionStore.setStage(.globe)
    }
}
