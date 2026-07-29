import SwiftUI

/// The whole kid-side pairing v2 flow behind one view.
///
/// The coordinator only needs to present this and handle `onJoined`; every
/// branch (restore / add-device / new child) is decided here, which keeps the
/// coordinator's own switch to a single case.
struct KidJoinFlowView: View {

    @StateObject private var model: KidJoinFlowModel
    let onJoined: (PairingCommitResult) -> Void
    let onBack: () -> Void

    init(
        client: PairingV2Client,
        store: PendingAdoptionStore,
        deviceSnapshot: [String: String],
        currentOwnerUUID: UUID?,
        onJoined: @escaping (PairingCommitResult) -> Void,
        onBack: @escaping () -> Void
    ) {
        _model = StateObject(wrappedValue: KidJoinFlowModel(
            client: client,
            store: store,
            deviceSnapshot: deviceSnapshot,
            currentOwnerUUID: currentOwnerUUID
        ))
        self.onJoined = onJoined
        self.onBack = onBack
    }

    var body: some View {
        VStack {
            switch model.stage {
            case .scanning:
                KidJoinScanStep(onScanned: { invite in
                    Task { await model.present(invite) }
                })

            case .resolving:
                ProgressView("Checking that code…")

            case .offerRestore(let childName):
                KidRestoreOfferStep(childName: childName) { choice in
                    Task { await model.choose(choice) }
                }

            case .confirmAddDevice(let childName):
                KidAddDeviceConfirmStep(childName: childName) {
                    Task { await model.choose(.invited) }
                }

            case .collectNewChildProfile:
                KidNewChildProfileStep { profile in
                    Task { await model.choose(.invited, profile: profile) }
                }

            case .committing:
                ProgressView("Setting up…")

            case .joined(let result):
                ProgressView("Almost there…")
                    .task { onJoined(result) }

            case .failed(let message):
                VStack(spacing: 16) {
                    Text(message)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                    Button("Try again") { onBack() }
                        .buttonStyle(.bordered)
                }
                .padding()
            }
        }
    }
}
