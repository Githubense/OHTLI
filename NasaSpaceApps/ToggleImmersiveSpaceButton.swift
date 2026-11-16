import SwiftUI

struct ToggleImmersiveSpaceButton: View {
    @Environment(MissionStore.self) private var missionStore
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace
    @Environment(\.openImmersiveSpace) private var openImmersiveSpace

    var body: some View {
        Button(action: toggleImmersiveSpace) {
            Label(buttonTitle, systemImage: missionStore.immersiveSpaceState == .open ? "rectangle.portrait.and.arrow.right" : "visionpro")
        }
        .disabled(missionStore.immersiveSpaceState == .inTransition)
        .buttonStyle(.borderedProminent)
    }

    private var buttonTitle: String {
        if missionStore.immersiveSpaceState == .open { return "Exit Immersive" }
        return missionStore.stage == .habitat ? "Enter Habitat Bay" : "Enter Drone View"
    }

    private func toggleImmersiveSpace() {
        Task { @MainActor in
            switch missionStore.immersiveSpaceState {
            case .open:
                missionStore.immersiveSpaceState = .inTransition
                await dismissImmersiveSpace()
            case .closed:
                missionStore.immersiveSpaceState = .inTransition
                switch await openImmersiveSpace(id: missionStore.immersiveSpaceID) {
                case .opened:
                    break // ImmersiveView.onAppear owns the open state.
                case .userCancelled, .error:
                    missionStore.immersiveSpaceState = .closed
                @unknown default:
                    missionStore.immersiveSpaceState = .closed
                }
            case .inTransition:
                break
            }
        }
    }
}
