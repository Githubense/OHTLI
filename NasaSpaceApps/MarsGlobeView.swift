import RealityKit
import SwiftUI
import UIKit

struct MarsGlobeView: View {
    @Environment(MissionStore.self) private var missionStore
    @State private var globeRoot = Entity()
    @State private var globeRotation: CGFloat = 0
    @GestureState private var dragRotation: CGFloat = 0

    var body: some View {
        RealityView { content in
            let globeTexture = await MarsTextureLoader.loadAsset(named: "MarsMola")
            var globeMaterial = UnlitMaterial(color: .white)
            if let globeTexture {
                var globeColor = globeMaterial.color
                globeColor.texture = .init(globeTexture)
                globeMaterial.color = globeColor
            }
            let mars = ModelEntity(
                mesh: .generateSphere(radius: 0.155),
                materials: [globeMaterial]
            )
            mars.name = "mars-globe"
            globeRoot.addChild(mars)

            for landmark in missionStore.landmarks {
                guard let coordinate = landmark.coordinate else { continue }
                let color: UIColor = landmark.id == "jezero-crater" ? .systemTeal : .systemOrange
                addMarker(
                    named: landmark.id,
                    at: position(for: coordinate, radius: 0.160),
                    color: color,
                    radius: 0.005,
                    to: globeRoot
                )
            }

            for (index, crew) in missionStore.crewTelemetry.enumerated() {
                let coordinate = approximateCoordinate(for: crew.point)
                addMarker(
                    named: crew.id,
                    at: position(for: coordinate, radius: 0.165),
                    color: index == 0 ? .systemGreen : .systemCyan,
                    radius: 0.004,
                    to: globeRoot
                )
            }
            content.add(globeRoot)
        } update: { _ in
            let yaw = Float(globeRotation + dragRotation)
            globeRoot.orientation = simd_quatf(angle: yaw, axis: SIMD3<Float>(0, 1, 0))
        }
        .gesture(
            DragGesture(minimumDistance: 4)
                .updating($dragRotation) { value, state, _ in
                    state = value.translation.width / 260
                }
                .onEnded { value in
                    globeRotation += value.translation.width / 260
                }
        )
        .simultaneousGesture(
            SpatialTapGesture().targetedToAnyEntity().onEnded { value in
                let name = value.entity.name
                if name.hasPrefix("crew-") {
                    missionStore.selectCrew(name)
                } else if missionStore.landmarks.contains(where: { $0.id == name }) {
                    missionStore.selectLandmark(name)
                }
            }
        )
        .accessibilityLabel("Interactive Mars globe with approximate regional landmarks and simulated crew beacons")
    }

    private func addMarker(named name: String, at position: SIMD3<Float>, color: UIColor, radius: Float, to root: Entity) {
        let marker = ModelEntity(
            mesh: .generateSphere(radius: radius),
            materials: [UnlitMaterial(color: color)]
        )
        marker.name = name
        marker.position = position
        marker.components.set(InputTargetComponent())
        marker.components.set(CollisionComponent(shapes: [.generateSphere(radius: radius * 1.8)]))
        marker.components.set(HoverEffectComponent())
        root.addChild(marker)
    }

    private func position(for coordinate: PlanetCoordinate, radius: Float) -> SIMD3<Float> {
        let latitude = Float(coordinate.latitudeDegrees * .pi / 180)
        let longitude = Float(coordinate.longitudeDegreesEast * .pi / 180)
        let cosLatitude = cos(latitude)
        return SIMD3(
            radius * cosLatitude * cos(longitude),
            radius * sin(latitude),
            radius * cosLatitude * sin(longitude)
        )
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
        let longitude = metadata.sourceLocation.longitudeCenterDegreesEast + eastMeters / longitudeScale
        return PlanetCoordinate(latitudeDegrees: latitude, longitudeDegreesEast: longitude)
    }
}

struct CrewTelemetryPill: View {
    var telemetry: CrewTelemetry
    var isSelected: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Circle()
                    .fill(telemetry.radioLineOfSight ? Color.green : Color.orange)
                    .frame(width: 8, height: 8)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        Text(telemetry.callsign).font(.headline)
                        Text("SIMULATED").font(.system(size: 9, weight: .bold, design: .rounded))
                            .foregroundStyle(.orange)
                    }
                    Text("\(Int(telemetry.metabolicWatts)) W · O₂ \(Int(telemetry.oxygenPercent))% · LoS \(telemetry.radioLineOfSight ? "YES" : "NO")")
                        .font(.caption2.monospacedDigit())
                }
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 9)
            .glassBackgroundEffect(in: Capsule())
            .overlay(Capsule().stroke(isSelected ? Color.green.opacity(0.8) : Color.white.opacity(0.15), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(telemetry.callsign), simulated crew telemetry")
    }
}
