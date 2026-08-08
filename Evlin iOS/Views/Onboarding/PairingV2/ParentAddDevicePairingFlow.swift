import SwiftUI

/// The one parent-side device-pairing presentation. Both Profile and Settings
/// enter through this view with a concrete child, so neither can mint a
/// `new_child` invite while adding another device.
struct ParentAddDevicePairingFlow: View {
    let kidName: String
    let targetChildProfileID: UUID
    let onDone: () -> Void
    let onCancel: () -> Void

    @StateObject private var model: ParentInviteModel
    @State private var paired = false

    init(
        kidName: String,
        targetChildProfileID: UUID,
        apiClient: APIClient,
        onDone: @escaping () -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.kidName = kidName
        self.targetChildProfileID = targetChildProfileID
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
                    AddDeviceSuccessStep(kidName: kidName, onDone: onDone)
                } else {
                    ParentInviteStep(
                        model: model,
                        purpose: .addDevice,
                        targetChildProfileID: targetChildProfileID,
                        targetChildName: kidName,
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
}

private struct AddDeviceSuccessStep: View {
    let kidName: String
    let onDone: () -> Void

    private var name: String {
        let trimmed = kidName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "your kid" : trimmed
    }

    var body: some View {
        OnboardingV2ScreenContainer(
            role: .parent,
            phase: "Device added",
            stepIndex: 1,
            stepTotal: 1,
            title: "Device added",
            subtitle: nil,
            dotsCount: 1,
            dotsCurrent: 0,
            content: {
                VStack(spacing: Spacing.xl) {
                    OnboardingV2SuccessCheck(role: .parent, size: 62)
                    Text("Connected to \(name)").onboardingV2TitleL()
                    Text("This device is now linked. You can return to \(name)'s profile.")
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
