import SwiftUI

struct ChildReadyStep: View {
    @AppStorage("onboardingComplete") private var onboardingComplete = false

    /// From child pairing (`EnterPairingCodeStep`); re-persist before leaving onboarding so post-onboarding doesn’t briefly miss `evlin.childDeviceID`.
    let childDeviceID: UUID?
    let familyID: UUID?

    let onEnter: () -> Void

    var body: some View {
        VStack(spacing: Spacing.section) {
            Spacer()

            Circle()
                .fill(Color.evSecondaryContainer)
                .frame(width: 64, height: 64)
                .overlay(
                    Image(systemName: "checkmark.seal.fill")
                        .font(.system(size: 28, weight: .bold))
                        .foregroundStyle(Color.evSecondary)
                )

            VStack(spacing: Spacing.lg) {
                Text("All set!")
                    .font(.evHeadlineLarge)
                    .foregroundStyle(Color.evPrimary)
                Text("Waiting for commands from your parent's Evlin.")
                    .font(.evBodyMedium)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(Color.evOnSurfaceVariant)
                    .padding(.horizontal, Spacing.xl)
            }

            Spacer()

            Button {
                // ORDER MATTERS: persist `evlin.childDeviceID` / `evlin.familyID`
                // STRICTLY BEFORE flipping `onboardingComplete`. The app-level
                // `.onChange(of: onboardingComplete)` in Evlin_iOSApp calls
                // `startPollerIfPaired()`, which reads those UserDefaults keys
                // synchronously — flipping the flag first would race it against
                // stale/missing pairing keys and leave the CommandPoller stopped.
                persistPairedIdentifiers()
                onboardingComplete = true
                onEnter()
            } label: {
                Text("Enter Evlin")
                    .font(.evLabelLarge)
                    .frame(maxWidth: .infinity)
            }
            .foregroundStyle(Color.evOnPrimary)
            .padding(.vertical, Spacing.lg)
            .background(
                RoundedRectangle(cornerRadius: CornerRadius.md)
                    .fill(Color.evPrimary)
            )
            .padding(.horizontal, Spacing.xl)
        }
        .padding(Spacing.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.evSurface)
    }

    /// Mirror `EnterPairingCodeStep` success path — covers edge cases where UserDefaults lagged vs coordinator state.
    private func persistPairedIdentifiers() {
        if let id = childDeviceID {
            UserDefaults.standard.set(id.uuidString, forKey: "evlin.childDeviceID")
        }
        if let fid = familyID {
            UserDefaults.standard.set(fid.uuidString, forKey: "evlin.familyID")
        }
    }
}
