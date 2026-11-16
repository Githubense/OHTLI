//
//  NasaSpaceAppsApp.swift
//  NasaSpaceApps
//
//  Created by Angel Adrian Pimienta Flores on 14/11/2026.
//

import SwiftUI

@main
struct NasaSpaceAppsApp: App {
    @State private var missionStore = MissionStore()
    @State private var sharePlayCoordinator = GroupSessionCoordinator()
    @State private var immersionStyle: any ImmersionStyle = .mixed

    var body: some Scene {
        WindowGroup(id: missionStore.missionWindowID) {
            ContentView()
                .environment(missionStore)
                .environment(sharePlayCoordinator)
                .task { sharePlayCoordinator.startObserving(store: missionStore) }
        }
        .windowStyle(.plain)
        .defaultSize(width: 420, height: 260)

        WindowGroup(id: missionStore.controlsWindowID, for: String.self) { _ in
            MissionControlsVolume()
                .environment(missionStore)
                .environment(sharePlayCoordinator)
        }
        .windowStyle(.volumetric)
        .defaultSize(width: 1.4, height: 1.4, depth: 1.4, in: .meters)

        ImmersiveSpace(id: missionStore.immersiveSpaceID) {
            ImmersiveView(immersionStyle: $immersionStyle)
                .environment(missionStore)
                .environment(sharePlayCoordinator)
                .onDisappear {
                    Task { @MainActor in
                        await Task.yield()
                        missionStore.immersiveSpaceState = .closed
                    }
                }
        }
        .immersionStyle(selection: $immersionStyle, in: .mixed, .full)
    }
}
