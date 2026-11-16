import SwiftUI

/// A small launch and recovery surface. Entering the mission is a direct user action so
/// visionOS can present the immersive space from a valid interaction context.
struct ContentView: View {
    @Environment(MissionStore.self) private var missionStore
    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
    @Environment(\.dismissWindow) private var dismissWindow

    @State private var isOpening = false

    var body: some View {
        VStack(spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "globe.americas.fill")
                    .font(.system(size: 28, weight: .light))
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 3) {
                    Text("OHTLI")
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                        .tracking(2.2)
                    Text("Mars EVA Navigator")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            if isOpening {
                ProgressView("Placing Mars in your space…")
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if let error = missionStore.immersionErrorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text("Place the Mars globe in your space, then explore a terrain sector.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack {
                Button {
                    Task { await enterMission() }
                } label: {
                    Label("Open Mars in Your Space", systemImage: "arrow.up.forward.and.arrow.down.backward")
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
                .disabled(isOpening || missionStore.immersiveSpaceState == .inTransition)

                #if DEBUG
                Menu("Developer") {
                    Button("Open ISS Habitat Showcase") {
                        Task { await enterMission(startingAt: .habitat) }
                    }
                    Button("Return to Mars Globe") {
                        Task { await enterMission(startingAt: .globe) }
                    }
                }
                .menuStyle(.borderlessButton)
                #endif
            }
        }
        .padding(22)
        .frame(width: 420, height: 220)
    }

    @MainActor
    private func enterMission(startingAt stage: MissionStage? = nil) async {
        guard missionStore.immersiveSpaceState == .closed else { return }
        if let stage { missionStore.setStage(stage) }
        isOpening = true
        missionStore.immersionErrorMessage = nil
        missionStore.immersiveSpaceState = .inTransition

        switch await openImmersiveSpace(id: missionStore.immersiveSpaceID) {
        case .opened:
            missionStore.immersiveSpaceState = .open
            dismissWindow(id: missionStore.missionWindowID)
        case .userCancelled:
            missionStore.immersiveSpaceState = .closed
            missionStore.immersionErrorMessage = "Immersive mode was cancelled. Tap Reopen Mission Space to try again."
        case .error:
            missionStore.immersiveSpaceState = .closed
            missionStore.immersionErrorMessage = "Mars could not open in your space. Tap Reopen Mission Space to try again."
        @unknown default:
            missionStore.immersiveSpaceState = .closed
            missionStore.immersionErrorMessage = "Mars could not open in your space. Tap Reopen Mission Space to try again."
        }
        isOpening = false
    }
}

#Preview(windowStyle: .automatic) {
    ContentView()
        .environment(MissionStore())
        .environment(GroupSessionCoordinator())
}
