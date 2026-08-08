import SwiftUI

/// The parent-side entry point for creating a child through the kid-device
/// onboarding flow. A new child does not exist until the kid completes the
/// profile step and commits the pairing invitation.
enum ParentNewChildPairingPresentation {
    static let invitePurpose: PairingInvitePurpose = .newChild
    static let targetChildProfileID: UUID? = nil
}

struct ParentNewChildPairingFlow: View {
    let onDone: () -> Void
    let onCancel: () -> Void

    @StateObject private var model: ParentInviteModel
    @State private var paired = false

    init(
        apiClient: APIClient,
        onDone: @escaping () -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.onDone = onDone
        self.onCancel = onCancel
        _model = StateObject(wrappedValue: ParentInviteModel(
            api: .live(client: apiClient)
        ))
    }

    var body: some View {
        NavigationStack {
            Group {
                if paired {
                    newChildSuccessStep
                } else {
                    ParentInviteStep(
                        model: model,
                        purpose: ParentNewChildPairingPresentation.invitePurpose,
                        targetChildProfileID: ParentNewChildPairingPresentation.targetChildProfileID,
                        targetChildName: nil,
                        showsOnboardingProgress: false
                    )
                    .onAppear { model.onJoined = { _ in paired = true } }
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(paired ? "Done" : "Cancel") {
                        paired ? onDone() : onCancel()
                    }
                }
            }
        }
    }

    private var newChildSuccessStep: some View {
        OnboardingV2ScreenContainer(
            role: .parent,
            phase: "Child added",
            stepIndex: 1,
            stepTotal: 1,
            title: "Child added",
            subtitle: nil,
            dotsCount: 1,
            dotsCurrent: 0,
            content: {
                VStack(spacing: Spacing.xl) {
                    OnboardingV2SuccessCheck(role: .parent, size: 62)
                    Text("Your child is connected").onboardingV2TitleL()
                    Text("Their profile and device are ready to manage.")
                        .onboardingV2Body()
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, Spacing.section)
            },
            footer: {
                OnboardingV2PrimaryButton("Done", role: .parent) {
                    onDone()
                }
            }
        )
    }
}
