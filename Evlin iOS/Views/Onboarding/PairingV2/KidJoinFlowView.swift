import SwiftUI

/// The whole kid-side pairing v2 flow behind one view.
///
/// The coordinator only needs to present this and handle `onJoined`; every
/// branch (restore / add-device / new child) is decided here, which keeps the
/// coordinator's own switch to a single case.
struct KidJoinFlowView: View {

    @StateObject private var model: KidJoinFlowModel
    /// Single-device demo: the tester just saw the code on the parent screen of
    /// this same phone, so feed it in rather than making them retype it. The
    /// resolve/commit path taken afterwards is identical to a real device's.
    let autoInvite: ScannedInvite?
    let onJoined: (PairingCommitResult) -> Void
    let onBack: () -> Void

    init(
        client: PairingV2Client,
        store: PendingAdoptionStore,
        deviceSnapshot: [String: String],
        currentOwnerUUID: UUID?,
        autoInvite: ScannedInvite? = nil,
        onJoined: @escaping (PairingCommitResult) -> Void,
        onBack: @escaping () -> Void
    ) {
        self.autoInvite = autoInvite
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
                .task {
                    if let autoInvite {
                        await model.present(autoInvite)
                    }
                }

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
