import SwiftUI

/// Matches the private copies the other parent v2 step files each keep. Swift
/// won't let one be internal while the rest stay private (the beta-agreement
/// file is off-limits), so this follows the existing convention rather than
/// half-changing it.
private let parentTotal = 12

/// The parent shows this; the kid device scans it.
///
/// Deliberately the mirror image of the old kid-side "Show this to your parent"
/// screen — same container, same QR card, same "OR TYPE THIS CODE" card — since
/// v2 only reverses who holds the code, not what the screen is.
///
/// Standalone like the kid-side steps: completion is reported through
/// `model.onJoined` and no coordinator is imported.
struct ParentInviteStep: View {

    @ObservedObject var model: ParentInviteModel

    /// Preselected when adding a device to an existing child. The parent picks
    /// the target BEFORE the code exists, which is what keeps the kid device
    /// from ever being told about the rest of the family.
    let purpose: PairingInvitePurpose
    let targetChildProfileID: UUID?
    let targetChildName: String?
    /// Onboarding shows this as one step of a sequence; Settings and Profile
    /// present it on its own, where a progress dot row would be claiming the
    /// parent is partway through a setup they already finished.
    var showsOnboardingProgress: Bool = true

    private var title: String {
        purpose == .addDevice ? "Add a device" : "Show this to the kid's phone"
    }

    private var subtitle: String {
        if purpose == .addDevice, let name = targetChildName, !name.isEmpty {
            return "Scan this from \(name)'s new phone."
        }
        return "Open Evlin on the kid's phone and scan this."
    }

    /// "4 8 2 9 1 0" — space-separated for the big code readout.
    private func spaced(_ code: String) -> String {
        code.map(String.init).joined(separator: " ")
    }

    var body: some View {
        OnboardingV2ScreenContainer(
            role: .parent,
            phase: "2 · Pair",
            stepIndex: 6,
            stepTotal: parentTotal,
            title: title,
            subtitle: subtitle,
            dotsCount: showsOnboardingProgress ? parentTotal : nil,
            dotsCurrent: showsOnboardingProgress ? 5 : nil,
            content: {
                switch model.stage {
                case .idle, .minting:
                    codeCards(invite: nil)

                case .showing(let invite):
                    VStack(spacing: 12) {
                        codeCards(invite: invite)
                        Text("Waiting for the device to join…")
                            .font(OnboardingV2Theme.Typography.bodyXS)
                            .foregroundStyle(OnboardingV2Theme.Palette.onSurfaceVariant)
                            .frame(maxWidth: .infinity)
                    }

                case .joined(let childName, let deviceLabel, let resolution):
                    joined(childName: childName, deviceLabel: deviceLabel,
                           resolution: resolution)

                case .expired:
                    retry(message: "That code expired.")

                case .failed(let message):
                    retry(message: message)
                }
            },
            footer: { EmptyView() }
        )
        .task { await mint() }
        .onDisappear { model.stopPolling() }
    }

    /// The QR + typed-code pair. `nil` renders the same shimmer the kid screen
    /// used while its code was minting, so the layout doesn't jump.
    @ViewBuilder
    private func codeCards(invite: PairingInviteCreated?) -> some View {
        VStack(spacing: 12) {
            OnboardingV2Card {
                HStack {
                    Spacer(minLength: 0)
                    if let invite {
                        OnboardingV2QRImage(string: invite.qrPayload)
                    } else {
                        OnboardingV2FauxQR()
                    }
                    Spacer(minLength: 0)
                }
            }

            OnboardingV2Card {
                VStack(spacing: 4) {
                    Text("OR TYPE THIS CODE")
                        .font(OnboardingV2Theme.Typography.bodyXS)
                        .tracking(1)
                        .foregroundStyle(OnboardingV2Theme.Palette.onSurfaceVariant)
                        .frame(maxWidth: .infinity)
                    if let invite {
                        Text(spaced(invite.codeDisplay))
                            .font(.system(size: 24, weight: .bold))
                            .tracking(5)
                            .foregroundStyle(OnboardingV2Theme.Palette.primary)
                            .frame(maxWidth: .infinity)
                    } else {
                        ProgressView().controlSize(.small)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 2)
                    }
                }
            }
        }
    }

    private func joined(childName: String?, deviceLabel: String?,
                        resolution: String?) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 44, weight: .semibold))
                .foregroundStyle(OnboardingV2Theme.Palette.secondary)
            Text(resolution == "restore" ? "Device restored" : "Device connected")
                .font(OnboardingV2Theme.Typography.navButton)
                .foregroundStyle(OnboardingV2Theme.Palette.primary)
            if let childName {
                Text(deviceLabel.map { "\($0) is now set up for \(childName)." }
                     ?? "Set up for \(childName).")
                    .font(OnboardingV2Theme.Typography.bodyXS)
                    .foregroundStyle(OnboardingV2Theme.Palette.onSurfaceVariant)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func retry(message: String) -> some View {
        // Centred rather than pinned to the top: with no QR to anchor the
        // layout, top-aligned text left the screen looking broken.
        VStack(spacing: 6) {
            Spacer(minLength: 0)
            Text(message)
                .font(OnboardingV2Theme.Typography.bodyXS)
                .foregroundStyle(OnboardingV2Theme.Palette.error)
                .multilineTextAlignment(.center)
            Button("Get a new code") { Task { await mint() } }
                .font(OnboardingV2Theme.Typography.navButton)
                .foregroundStyle(OnboardingV2Theme.Palette.primary)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
    }

    private func mint() async {
        await model.mint(purpose: purpose, target: targetChildProfileID)
    }
}
