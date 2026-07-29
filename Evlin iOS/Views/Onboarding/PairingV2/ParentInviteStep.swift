import SwiftUI

/// The parent shows this; the kid device scans it.
///
/// Standalone like the kid-side steps — it reports completion through
/// `model.onJoined` and imports no coordinator.
struct ParentInviteStep: View {

    @ObservedObject var model: ParentInviteModel

    /// Preselected when adding a device to an existing child. The parent picks
    /// the target BEFORE the code exists, which is what keeps the kid device
    /// from ever being told about the rest of the family.
    let purpose: PairingInvitePurpose
    let targetChildProfileID: UUID?
    let targetChildName: String?

    var body: some View {
        VStack(spacing: 24) {
            header

            switch model.stage {
            case .idle, .minting:
                ProgressView("Creating a code…")

            case .showing(let invite):
                OnboardingV2QRImage(string: invite.qrPayload)

                VStack(spacing: 6) {
                    Text("Or type this code")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Text(invite.codeDisplay)
                        .font(.title.monospacedDigit().weight(.semibold))
                        .tracking(4)
                }

                Text("Waiting for the device to join…")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

            case .joined(let childName, let deviceLabel, let resolution):
                joined(childName: childName, deviceLabel: deviceLabel,
                       resolution: resolution)

            case .expired:
                retry(message: "That code expired.")

            case .failed(let message):
                retry(message: message)
            }
        }
        .padding()
        .task { await mint() }
        .onDisappear { model.stopPolling() }
    }

    private var header: some View {
        VStack(spacing: 8) {
            Text(purpose == .addDevice ? "Add a device" : "Set up a device")
                .font(.title2.bold())
            if let name = targetChildName, purpose == .addDevice {
                Text("This will become another one of \(name)'s devices.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            } else {
                Text("Open Evlin on the kid's device and scan this.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
    }

    private func joined(childName: String?, deviceLabel: String?,
                        resolution: String?) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .font(.largeTitle)
                .foregroundStyle(.green)
            Text(resolution == "restore" ? "Device restored" : "Device connected")
                .font(.headline)
            if let childName {
                Text(deviceLabel.map { "\($0) is now set up for \(childName)." }
                     ?? "Set up for \(childName).")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
    }

    private func retry(message: String) -> some View {
        VStack(spacing: 12) {
            Text(message)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Get a new code") {
                Task { await mint() }
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private func mint() async {
        await model.mint(purpose: purpose, target: targetChildProfileID)
    }
}
