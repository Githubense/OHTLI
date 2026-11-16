import RealityKit
import SwiftUI
import UIKit

struct TabletopMapView: View {
    @Environment(MissionStore.self) private var missionStore

    @State private var terrainRoot = Entity()

    var body: some View {
        VStack(spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text("FIELD OPERATIONS")
                    .font(.caption.weight(.bold))
                    .tracking(1.4)
                Text("Gale Curiosity DTM context")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    missionStore.setStage(.globe)
                } label: {
                    Label("Globe", systemImage: "globe.americas.fill")
                }
                .buttonStyle(.bordered)
            }
            .padding(.horizontal, 24)

            GeometryReader { geometry in
                let center = CGPoint(x: geometry.size.width / 2, y: geometry.size.height / 2)
                ZStack {
                    Circle()
                        .stroke(Color.white.opacity(0.30), lineWidth: 1)
                        .frame(width: 610, height: 610)
                    Circle()
                        .stroke(Color.orange.opacity(0.55), lineWidth: 4)
                        .frame(width: 580, height: 580)

                    mapCutout
                        .frame(width: 480, height: 480)
                        .overlay {
                            ZStack {
                                Circle().stroke(Color.orange.opacity(0.75), lineWidth: 2)
                                GeometryReader { proxy in
                                    ForEach(missionStore.crewTelemetry) { crew in
                                        CrewMapTelemetryPill(
                                            telemetry: crew,
                                            isSelected: missionStore.selectedCrewID == crew.id
                                        ) {
                                            missionStore.selectCrew(crew.id)
                                        }
                                        .position(crewPillPosition(crew, in: proxy.size))
                                    }
                                }
                            }
                            .clipShape(Circle())
                        }
                        .position(center)

                    ForEach(0..<8, id: \.self) { index in
                        rimControl(at: index)
                            .position(radialPosition(index: index, count: 8, radius: 330, center: center))
                    }

                    VStack(spacing: 4) {
                        Text("ALTADENA CASE STUDY")
                            .font(.caption2.weight(.bold))
                            .tracking(1.1)
                        Text("synthetic route & obstacle overlay")
                            .font(.system(size: 9, weight: .medium))
                    }
                    .padding(.horizontal, 11)
                    .padding(.vertical, 7)
                    .glassBackgroundEffect(in: Capsule())
                    .position(x: center.x, y: center.y - 255)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(width: 760, height: 680)

            HStack(spacing: 10) {
                CrewTelemetryPill(
                    telemetry: missionStore.crewTelemetry[0],
                    isSelected: missionStore.selectedCrewID == "crew-01"
                ) { missionStore.selectCrew("crew-01") }
                CrewTelemetryPill(
                    telemetry: missionStore.crewTelemetry[1],
                    isSelected: missionStore.selectedCrewID == "crew-02"
                ) { missionStore.selectCrew("crew-02") }
                Spacer(minLength: 8)
                Button {
                    missionStore.setPlayback(!missionStore.liveEVAPlayback)
                } label: {
                    Label(missionStore.liveEVAPlayback ? "Pause EVA" : "Live EVA Playback", systemImage: missionStore.liveEVAPlayback ? "pause.fill" : "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)

                Button {
                    missionStore.setSolarStormActive(!missionStore.solarStormActive)
                } label: {
                    Label(missionStore.solarStormActive ? "End Storm" : "Solar Storm", systemImage: "sun.max.trianglebadge.exclamationmark")
                }
                .buttonStyle(.bordered)
                .tint(missionStore.solarStormActive ? .orange : .primary)
            }
            .padding(.horizontal, 24)

            HStack(spacing: 9) {
                routeSummary
                Spacer()
                Button {
                    missionStore.setStage(.drone)
                } label: {
                    Label("Drone View", systemImage: "view.3d")
                }
                .buttonStyle(.bordered)
                Button {
                    missionStore.setStage(.habitat)
                } label: {
                    Label("Habitat Bay", systemImage: "door.left.hand.open")
                }
                .buttonStyle(.bordered)
                ToggleImmersiveSpaceButton()
            }
            .padding(.horizontal, 24)

            Text("Base DEM: HiRISE \(missionStore.terrainAsset?.terrain.sourceProduct ?? "unavailable") · \(missionStore.terrainAsset?.terrain.cellSizeMeters ?? 0, specifier: "%.2f") m grid · Altadena overlap unverified · telemetry / hazards synthetic")
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .padding(.horizontal, 24)
        }
        .padding(.vertical, 14)
        .frame(minWidth: 800, minHeight: 900)
        .task {
            missionStore.stage = .tabletop
            missionStore.recalculateRoute(publish: false)
        }
    }

    private var mapCutout: some View {
        ZStack {
            if missionStore.hasGaleTerrainContext, let terrain = missionStore.terrainAsset?.terrain {
                RealityView { content in
                    guard let mesh = try? TerrainMeshFactory.makeMesh(
                        grid: terrain,
                        widthMeters: 0.44,
                        depthMeters: 0.44,
                        heightScale: 0.00043,
                        circularRadiusMeters: 0.22
                    ) else { return }
                    let terrainModel = ModelEntity(
                        mesh: mesh,
                        materials: [SimpleMaterial(color: UIColor(red: 0.55, green: 0.25, blue: 0.13, alpha: 1), roughness: 0.82, isMetallic: false)]
                    )
                    terrainModel.name = "hiRise-terrain-mesh"
                    terrainRoot.addChild(terrainModel)
                    addPin(point: GridPoint(x: 18, y: 64), name: "Airlock Alpha · hypothetical", color: .systemGreen, grid: terrain, root: terrainRoot)
                    addPin(point: GridPoint(x: 92, y: 64), name: "Altadena target · synthetic", color: .systemOrange, grid: terrain, root: terrainRoot)
                    for crew in missionStore.crewTelemetry {
                        addPin(point: crew.point, name: crew.callsign, color: .systemCyan, grid: terrain, root: terrainRoot, radius: 0.010)
                    }
                    content.add(terrainRoot)
                } update: { _ in
                    for crew in missionStore.crewTelemetry {
                        terrainRoot.findEntity(named: crew.callsign)?.position = localPosition(point: crew.point, grid: terrain, radius: 0.22, heightScale: 0.00043, lift: 0.008)
                    }
                }
                .overlay {
                    TerrainCanvas(
                        grid: terrain,
                        comparison: missionStore.routeComparison,
                        showSlope: missionStore.activeLayers.contains(.slopeTraction),
                        showHazards: missionStore.activeLayers.contains(.terrainClass),
                        showRadiation: missionStore.activeLayers.contains(.radiationShelter),
                        showThermal: missionStore.activeLayers.contains(.thermalShadow),
                        showRadio: missionStore.activeLayers.contains(.radioLineOfSight)
                    )
                    .clipShape(Circle())
                }
            } else {
                Circle()
                    .fill(.black.opacity(0.5))
                    .overlay {
                        VStack(spacing: 9) {
                            Image(systemName: "map.slash").font(.largeTitle)
                            Text("No site-matched terrain bundled for this landmark.")
                                .multilineTextAlignment(.center)
                        }
                        .padding(28)
                    }
            }
        }
    }

    @ViewBuilder
    private func rimControl(at index: Int) -> some View {
        if index < MissionLayer.allCases.count {
            let layer = MissionLayer.allCases[index]
            rimButton(shortTitle(for: layer), selected: missionStore.activeLayers.contains(layer)) {
                missionStore.toggleLayer(layer)
            }
        } else {
            let preset = RouteWeightPreset.allCases[index - MissionLayer.allCases.count]
            rimButton(preset.title, selected: missionStore.weightPreset == preset) {
                missionStore.chooseWeights(preset)
            }
        }
    }

    private func rimButton(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .frame(width: 100, height: 36)
                .foregroundStyle(selected ? Color.white : Color.secondary)
                .glassBackgroundEffect(in: Capsule())
                .overlay(Capsule().stroke(selected ? Color.orange.opacity(0.75) : Color.white.opacity(0.15), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private func shortTitle(for layer: MissionLayer) -> String {
        switch layer {
        case .optical: "Optical"
        case .themisInfrared: "THEMIS IR"
        case .themisNightInfrared: "THEMIS Night IR"
        case .globalGeology: "Global Geology"
        case .molaElevation: "MOLA"
        case .slopeTraction: "Slope / Traction"
        case .terrainClass: "Boxwork / Sand"
        case .radiationShelter: "Radiation / Shelter"
        case .thermalShadow: "Thermal Shadow"
        case .radioLineOfSight: "Radio LoS"
        }
    }

    private var routeSummary: some View {
        Group {
            if let comparison = missionStore.routeComparison, let failure = comparison.failureReason {
                Label(failure.message, systemImage: "exclamationmark.triangle")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            } else if let comparison = missionStore.routeComparison {
                HStack(spacing: 11) {
                    Label("A* \(Int(comparison.routed.distanceMeters.rounded())) m", systemImage: "point.topleft.down.curvedto.point.bottomright.up")
                    Text("vs \(Int(comparison.straightLineDistanceMeters.rounded())) m straight")
                    Text("\(comparison.routed.walkBackMarginPercent, format: .number.precision(.fractionLength(0)))% demo reserve")
                    Text("\(Int(comparison.routed.radioLineOfSightFraction * 100))% LoS")
                }
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
            } else {
                Label("Route unavailable: site or 50% demo reserve gate", systemImage: "exclamationmark.triangle")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
        }
    }

    private func radialPosition(index: Int, count: Int, radius: CGFloat, center: CGPoint) -> CGPoint {
        let angle = -CGFloat.pi / 2 + (2 * CGFloat.pi * CGFloat(index) / CGFloat(count))
        return CGPoint(x: center.x + cos(angle) * radius, y: center.y + sin(angle) * radius)
    }

    private func crewPillPosition(_ crew: CrewTelemetry, in size: CGSize) -> CGPoint {
        guard let grid = missionStore.terrainAsset?.terrain else {
            return CGPoint(x: size.width / 2, y: size.height / 2)
        }
        let markerX = CGFloat(crew.point.x) / CGFloat(grid.width - 1) * size.width
        let markerY = CGFloat(crew.point.y) / CGFloat(grid.height - 1) * size.height
        let side: CGFloat = crew.point.x < grid.width / 2 ? 1 : -1
        let verticalOffset: CGFloat = crew.id == "crew-01" ? -26 : 29
        return CGPoint(
            x: min(size.width - 90, max(90, markerX + side * 88)),
            y: min(size.height - 28, max(28, markerY + verticalOffset))
        )
    }

    private func addPin(point: GridPoint, name: String, color: UIColor, grid: TerrainGrid, root: Entity, radius: Float = 0.012) {
        let pin = ModelEntity(mesh: .generateSphere(radius: radius), materials: [UnlitMaterial(color: color)])
        pin.name = name
        pin.position = localPosition(point: point, grid: grid, radius: 0.22, heightScale: 0.00043, lift: 0.008)
        root.addChild(pin)
    }

    private func localPosition(point: GridPoint, grid: TerrainGrid, radius: Float, heightScale: Float, lift: Float) -> SIMD3<Float> {
        let x = (Float(point.x) / Float(grid.width - 1) - 0.5) * radius * 2
        let z = (Float(point.y) / Float(grid.height - 1) - 0.5) * radius * 2
        let elevation = Float(grid.relativeElevation(at: point)) * heightScale
        return SIMD3(x, elevation + lift, z)
    }
}

private struct CrewMapTelemetryPill: View {
    var telemetry: CrewTelemetry
    var isSelected: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Circle()
                        .fill(telemetry.radioLineOfSight ? Color.green : Color.orange)
                        .frame(width: 6, height: 6)
                    Text(telemetry.callsign)
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                    Text("\(Int(telemetry.metabolicWatts)) W")
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                }
                Text("O₂ \(Int(telemetry.oxygenPercent))% · SWME \(telemetry.coolingWaterKilograms, format: .number.precision(.fractionLength(1))) kg")
                    .font(.system(size: 8, weight: .medium, design: .monospaced))
                Text("Dose \(telemetry.radiationDoseMicroSieverts, format: .number.precision(.fractionLength(1))) µSv · LoS \(telemetry.radioLineOfSight ? "YES" : "NO") · SYNTHETIC")
                    .font(.system(size: 7, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .glassBackgroundEffect(in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(isSelected ? Color.green : Color.white.opacity(0.18), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(telemetry.callsign), simulated suit telemetry at terrain position")
    }
}

/// Converts points in the rendered map's coordinate space to its DEM grid.
/// A circular interaction area matches the clipped tabletop in any view size.
enum TerrainMapCoordinates {
    nonisolated static func gridPoint(at location: CGPoint, size: CGSize, grid: TerrainGrid, clampToCircle: Bool = false) -> GridPoint? {
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0,
              location.x.isFinite, location.y.isFinite, grid.width > 1, grid.height > 1 else { return nil }
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let radius = min(size.width, size.height) / 2
        var dx = location.x - center.x
        var dy = location.y - center.y
        let distance = hypot(dx, dy)
        if distance > radius {
            guard clampToCircle else { return nil }
            dx *= radius / distance
            dy *= radius / distance
        }
        var x = min(grid.width - 1, max(0, Int(((center.x + dx) / size.width * CGFloat(grid.width - 1)).rounded())))
        var y = min(grid.height - 1, max(0, Int(((center.y + dy) / size.height * CGFloat(grid.height - 1)).rounded())))
        // Grid rounding at the boundary can otherwise place a marker just outside the visible disk.
        var adjustments = 0
        while hypot(CGFloat(x) / CGFloat(grid.width - 1) * size.width - center.x,
                    CGFloat(y) / CGFloat(grid.height - 1) * size.height - center.y) > radius {
            // Tiny grids need not contain any grid point inside a circular cutout.
            guard adjustments < grid.width + grid.height else { return nil }
            let nx = (CGFloat(x) / CGFloat(grid.width - 1) * size.width - center.x) / radius
            let ny = (CGFloat(y) / CGFloat(grid.height - 1) * size.height - center.y) / radius
            if abs(nx) >= abs(ny) { x += nx > 0 ? -1 : 1 }
            else { y += ny > 0 ? -1 : 1 }
            adjustments += 1
        }
        return GridPoint(x: x, y: y)
    }
}

struct TerrainCanvas: View {
    var grid: TerrainGrid
    var comparison: RouteComparison?
    /// Comparisons are computed on the routing grid, which can be coarser than the displayed DEM.
    var routeGrid: TerrainGrid? = nil
    var showSlope: Bool
    var showHazards: Bool
    var showRadiation: Bool
    var showThermal: Bool
    var showRadio: Bool
    var showsRoutes = true
    var editableMarkers: [EditableMissionMarker] = []
    var onMarkerMoved: (String, GridPoint) -> Void = { _, _ in }
    var onMapTap: (GridPoint) -> Void = { _ in }

    @State private var draggingMarkerID: String?
    @State private var dragLocation: CGPoint?

    var body: some View {
        Canvas { context, size in
            let strideSize = 1
            let blockWidth = size.width / CGFloat(grid.width)
            let blockHeight = size.height / CGFloat(grid.height)

            if showSlope {
                for y in stride(from: 0, to: grid.height, by: strideSize) {
                    for x in stride(from: 0, to: grid.width, by: strideSize) {
                        let slope = localSlopeDegrees(at: GridPoint(x: x, y: y))
                        let color: Color
                        if slope < 7 { color = .green.opacity(0.58) }
                        else if slope < 14 { color = .yellow.opacity(0.62) }
                        else { color = .red.opacity(0.70) }
                        let rect = CGRect(
                            x: CGFloat(x) * blockWidth,
                            y: CGFloat(y) * blockHeight,
                            width: blockWidth,
                            height: blockHeight
                        )
                        context.fill(Path(rect), with: .color(color))
                    }
                }
            }

            if showHazards {
                context.fill(Path(roundedRect: rect(x: 31, y: 49, width: 48, height: 30, size: size), cornerRadius: 8), with: .color(.yellow.opacity(0.14)))
                context.fill(Path(roundedRect: rect(x: 0, y: 42, width: 128, height: 6, size: size), cornerRadius: 4), with: .color(.green.opacity(0.22)))
                context.fill(Path(roundedRect: rect(x: 45, y: 54, width: 11, height: 20, size: size), cornerRadius: 8), with: .color(.orange.opacity(0.50)))
            }

            if showRadiation {
                let habitat = location(GridPoint(x: 18, y: 64), size: size)
                let shelterRadiusMeters = 0.85 * 60 * 30
                let shelterRadius = CGFloat(shelterRadiusMeters / grid.cellSizeMeters) * size.width / CGFloat(grid.width - 1)
                let shelterCircle = CGRect(x: habitat.x - shelterRadius, y: habitat.y - shelterRadius, width: shelterRadius * 2, height: shelterRadius * 2)
                context.fill(Path(ellipseIn: shelterCircle), with: .color(.mint.opacity(0.07)))
                context.stroke(Path(ellipseIn: shelterCircle), with: .color(.mint.opacity(0.65)), style: StrokeStyle(lineWidth: 2, dash: [5, 5]))
            }

            if showThermal {
                let shadowRect = rect(x: 30, y: 84, width: 35, height: 14, size: size)
                context.fill(Path(roundedRect: shadowRect, cornerRadius: 8), with: .color(.cyan.opacity(0.38)))
            }

            if showRadio {
                let radioRect = rect(x: 45, y: 54, width: 11, height: 20, size: size)
                context.fill(Path(roundedRect: radioRect, cornerRadius: 8), with: .color(.purple.opacity(0.40)))
                context.stroke(Path(roundedRect: radioRect.insetBy(dx: -5, dy: -5), cornerRadius: 10), with: .color(.purple.opacity(0.9)), style: StrokeStyle(lineWidth: 1.5, dash: [4, 4]))
            }

            if showsRoutes, let comparison {
                draw(comparison.straightLinePath, size: size, in: &context, color: .red.opacity(0.95), width: 3, dashed: true)
                draw(comparison.routed.path, size: size, in: &context, color: .green.opacity(0.98), width: 4, dashed: false)
            }
        }
        .overlay {
            GeometryReader { proxy in
                ZStack(alignment: .topLeading) {
                    ForEach(editableMarkers) { marker in
                        let point = draggingMarkerID == marker.id ? (dragLocation ?? location(marker.point, size: proxy.size)) : location(marker.point, size: proxy.size)
                        markerHandle(marker)
                            .position(point)
                            .gesture(
                                DragGesture(minimumDistance: 2, coordinateSpace: .named("terrain-map"))
                                    .onChanged { value in
                                        draggingMarkerID = marker.id
                                        dragLocation = value.location
                                    }
                                    .onEnded { value in
                                        if let point = TerrainMapCoordinates.gridPoint(at: value.location, size: proxy.size, grid: grid, clampToCircle: true) {
                                            onMarkerMoved(marker.id, point)
                                        }
                                        draggingMarkerID = nil
                                        dragLocation = nil
                                    }
                            )
                    }
                }
                .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
                .coordinateSpace(name: "terrain-map")
                .contentShape(Rectangle())
                .simultaneousGesture(
                    SpatialTapGesture(coordinateSpace: .local)
                        .onEnded { value in
                            guard let point = TerrainMapCoordinates.gridPoint(at: value.location, size: proxy.size, grid: grid) else { return }
                            if let airlock = editableMarkers.first(where: { $0.kind == .airlock }),
                               hypot(Double(point.x - airlock.point.x), Double(point.y - airlock.point.y)) < 3 {
                                return
                            }
                            onMapTap(point)
                        }
                )
            }
        }
        .accessibilityLabel("HiRISE terrain map. Tap to place the destination. Drag the airlock or science-stop marker to change the route.")
    }

    @ViewBuilder
    private func markerHandle(_ marker: EditableMissionMarker) -> some View {
        let color: Color = switch marker.kind {
        case .airlock, .shelter: .green
        case .scienceStop: .orange
        case .crew: .cyan
        case .waypoint: .yellow
        }
        HStack(spacing: 3) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(shortTitle(marker.title))
                .font(.system(size: 7, weight: .bold, design: .rounded))
                .lineLimit(1)
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 3)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().stroke(color.opacity(0.8), lineWidth: 0.8))
        .shadow(color: color.opacity(0.35), radius: 3)
        .contentShape(Capsule())
        .accessibilityLabel("Drag to move \(marker.title); position snaps to the terrain grid")
    }

    private func shortTitle(_ title: String) -> String {
        if title.localizedCaseInsensitiveContains("Airlock") { return "AIRLOCK" }
        if title.localizedCaseInsensitiveContains("Altadena") { return "ALTADENA" }
        if title.localizedCaseInsensitiveContains("Shelter") { return "SHELTER" }
        return title
    }

    private func draw(_ points: [GridPoint], size: CGSize, in context: inout GraphicsContext, color: Color, width: CGFloat, dashed: Bool) {
        guard points.count > 1 else { return }
        func displayPoint(_ point: GridPoint) -> GridPoint {
            guard let routeGrid, routeGrid.width > 1, routeGrid.height > 1 else { return point }
            return GridPoint(
                x: Int((Double(point.x) * Double(grid.width - 1) / Double(routeGrid.width - 1)).rounded()),
                y: Int((Double(point.y) * Double(grid.height - 1) / Double(routeGrid.height - 1)).rounded())
            )
        }
        var path = Path()
        path.move(to: location(displayPoint(points[0]), size: size))
        for point in points.dropFirst() { path.addLine(to: location(displayPoint(point), size: size)) }
        context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round, dash: dashed ? [8, 6] : []))
    }

    private func location(_ point: GridPoint, size: CGSize) -> CGPoint {
        CGPoint(
            x: CGFloat(point.x) / CGFloat(grid.width - 1) * size.width,
            y: CGFloat(point.y) / CGFloat(grid.height - 1) * size.height
        )
    }

    private func rect(x: Int, y: Int, width: Int, height: Int, size: CGSize) -> CGRect {
        CGRect(
            x: CGFloat(x) / CGFloat(grid.width) * size.width,
            y: CGFloat(y) / CGFloat(grid.height) * size.height,
            width: CGFloat(width) / CGFloat(grid.width) * size.width,
            height: CGFloat(height) / CGFloat(grid.height) * size.height
        )
    }

    private func localSlopeDegrees(at point: GridPoint) -> Double {
        let left = grid.elevation(at: GridPoint(x: max(0, point.x - 1), y: point.y))
        let right = grid.elevation(at: GridPoint(x: min(grid.width - 1, point.x + 1), y: point.y))
        let up = grid.elevation(at: GridPoint(x: point.x, y: max(0, point.y - 1)))
        let down = grid.elevation(at: GridPoint(x: point.x, y: min(grid.height - 1, point.y + 1)))
        let dx = (right - left) / (2 * grid.cellSizeMeters)
        let dy = (down - up) / (2 * grid.cellSizeMeters)
        return atan(hypot(dx, dy)) * 180 / .pi
    }
}
