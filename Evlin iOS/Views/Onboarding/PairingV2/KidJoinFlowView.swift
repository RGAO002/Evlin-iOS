import SwiftUI
import UIKit

/// The whole kid-side pairing v2 flow behind one view.
///
/// The coordinator only needs to present this and handle `onJoined`; every
/// branch (restore / add-device / new child) is decided here, which keeps the
/// coordinator's own switch to a single case.
struct KidJoinFlowView: View {

    @StateObject private var model: KidJoinFlowModel
    /// One auto-present per appearance of this flow; `onAppear` can fire again
    /// on a re-render and a second resolve would race the first.
    @State private var autoPresented = false
    // New-child pairing shares the normal onboarding profile surface instead
    // of maintaining a second, stripped-down name form in this flow.
    @State private var newChildName = ""
    @State private var newChildBirthYear: Int?
    @State private var newChildGender: String?
    @State private var newChildAvatar: UIImage?
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
                // Deliberately an UNSTRUCTURED task, not `.task`. Single
                // device hands the code over by changing the role and the step
                // together, and the role change rebuilds the view tree — which
                // cancelled a `.task`-owned resolve mid-flight. The server had
                // already recorded the resolution, so the tester was told "that
                // code didn't work" about a code that had in fact just worked,
                // with no way forward. Resolving must outlive one re-render.
                .onAppear {
                    guard let autoInvite, !autoPresented else { return }
                    autoPresented = true
                    Task { await model.present(autoInvite) }
                }

            case .resolving:
                ProgressView("Checking that code…")

            case .offerRestore(let childName, let canSetUpSomeoneNew):
                KidRestoreOfferStep(
                    childName: childName,
                    canSetUpSomeoneNew: canSetUpSomeoneNew,
                    onRestore: { Task { await model.choose(.restore) } },
                    onSetUpSomeoneNew: { model.setUpSomeoneNew() }
                )

            case .confirmAddDevice(let childName):
                KidAddDeviceConfirmStep(childName: childName) {
                    Task { await model.choose(.invited) }
                }

            case .collectNewChildProfile:
                ChildProfileStep(
                    name: $newChildName,
                    birthYear: $newChildBirthYear,
                    gender: $newChildGender,
                    pickedAvatar: $newChildAvatar,
                    onContinue: {
                        let profile = PairingNewChildProfile(
                            displayName: newChildName.trimmingCharacters(in: .whitespacesAndNewlines),
                            birthYear: newChildBirthYear,
                            gender: newChildGender
                        )
                        Task { await model.choose(.invited, profile: profile) }
                    }
                )

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
                    // "Try again" used to call `onBack()`, which on single
                    // device meant the parent's own code screen — a screen that
                    // cannot advance again, so the retry was a dead end. Retry
                    // the code we already hold; fall back to going back only
                    // when there is nothing to retry.
                    Button("Try again") {
                        if let autoInvite {
                            Task { await model.present(autoInvite) }
                        } else {
                            onBack()
                        }
                    }
                    .buttonStyle(.bordered)
                }
                .padding()
            }
        }
    }
}
