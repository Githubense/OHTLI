import Combine
import CoreTransferable
import GroupActivities
import Observation

struct MissionShareActivity: GroupActivity, Transferable {
    static let activityIdentifier = "pimienta.nasaspaceapps.mars-eva-mission"

    var metadata: GroupActivityMetadata {
        get async {
            var metadata = GroupActivityMetadata()
            metadata.title = "Mars EVA Mission"
            metadata.subtitle = "Plan and review a simulated Marswalk"
            metadata.type = .exploreTogether
            metadata.sceneAssociationBehavior = .content("mars-eva-mission")
            return metadata
        }
    }

    static var transferRepresentation: some TransferRepresentation {
        GroupActivityTransferRepresentation { _ in MissionShareActivity() }
    }
}

@MainActor
@Observable
final class GroupSessionCoordinator {
    private(set) var isActive = false
    private(set) var participantCount = 1

    @ObservationIgnored private var sessionTask: Task<Void, Never>?
    @ObservationIgnored private var messageTask: Task<Void, Never>?
    @ObservationIgnored private var participantTask: Task<Void, Never>?

    func startObserving(store: MissionStore) {
        guard sessionTask == nil else { return }
        sessionTask = Task { @MainActor in
            for await session in MissionShareActivity.sessions() {
                let messenger = GroupSessionMessenger(session: session)
                if let coordinator = await session.systemCoordinator {
                    var configuration = SystemCoordinator.Configuration()
                    configuration.supportsGroupImmersiveSpace = true
                    configuration.spatialTemplatePreference = .sideBySide.contentExtent(130)
                    coordinator.configuration = configuration
                }

                session.join()
                isActive = true
                participantCount = max(1, session.activeParticipants.count)
                store.sessionStatus = "SharePlay active · \(participantCount) participants"
                participantTask?.cancel()
                participantTask = Task { @MainActor in
                    for await participants in session.$activeParticipants.values {
                        guard !Task.isCancelled else { break }
                        participantCount = max(1, participants.count)
                        store.sessionStatus = "SharePlay active · \(participantCount) participants"
                    }
                }
                store.bindSnapshotPublisher { snapshot in
                    Task { try? await messenger.send(snapshot) }
                }
                Task { try? await messenger.send(store.currentSnapshot()) }

                messageTask?.cancel()
                messageTask = Task { @MainActor in
                    for await (snapshot, context) in messenger.messages(of: MissionStateSnapshot.self) {
                        guard context.source != session.localParticipant else { continue }
                        store.applyRemoteSnapshot(snapshot)
                    }
                }

                for await state in session.$state.values {
                    if case .invalidated = state {
                        isActive = false
                        participantCount = 1
                        store.sessionStatus = "Not sharing"
                        store.bindSnapshotPublisher { _ in }
                        messageTask?.cancel()
                        messageTask = nil
                        participantTask?.cancel()
                        participantTask = nil
                        break
                    }
                }
            }
        }
    }
}
