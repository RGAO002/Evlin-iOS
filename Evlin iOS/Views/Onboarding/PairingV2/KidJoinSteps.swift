import SwiftUI

/// Kid-side pairing v2 screens.
///
/// Every view here is standalone and reports outcomes through a closure. None
/// of them import or touch `OnboardingCoordinator`; the host app wires the
/// finished flow in at one point, which keeps this whole feature reviewable in
/// isolation and out of the beta work in progress.

// MARK: - Scan / type the invite

struct KidJoinScanStep: View {
    let onScanned: (ScannedInvite) -> Void

    @State private var typedCode = ""

    var body: some View {
        VStack(spacing: 24) {
            Text("Scan your parent's code")
                .font(.title2.bold())

            // The shared scanner already handles the permission states and
            // points at the typed-code field when the camera is unavailable,
            // so there is no separate fallback branch to maintain here.
            OnboardingV2QRScanner(onScan: { raw in
                guard let invite = ScannedInvite.parse(raw) else { return }
                onScanned(invite)
            })

            VStack(spacing: 8) {
                Text("Or type the code")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                TextField("000000", text: $typedCode)
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.center)
                    .font(.title3.monospacedDigit())
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: typedCode) { _, value in
                        // Six digits is the whole code, so submit on completion
                        // rather than making the kid find a button.
                        guard let invite = ScannedInvite.parse(value) else { return }
                        onScanned(invite)
                    }
            }
            .frame(maxWidth: 220)
        }
        .padding()
    }
}

// MARK: - Restore offer

struct KidRestoreOfferStep: View {
    let childName: String
    let onChoice: (AdoptionChoice) -> Void

    var body: some View {
        VStack(spacing: 20) {
            Text("Welcome back")
                .font(.title2.bold())
            Text("This device was set up for \(childName). Continue as \(childName), or start fresh?")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)

            Button("Continue as \(childName)") { onChoice(.restore) }
                .buttonStyle(.borderedProminent)
            Button("Set up as someone new") { onChoice(.invited) }
                .buttonStyle(.bordered)
        }
        .padding()
    }
}

// MARK: - Add-device confirmation

struct KidAddDeviceConfirmStep: View {
    let childName: String
    let onConfirm: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            Text("Add this device")
                .font(.title2.bold())
            Text("This will become another one of \(childName)'s devices.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button("Continue") { onConfirm() }
                .buttonStyle(.borderedProminent)
        }
        .padding()
    }
}

// MARK: - New child profile

struct KidNewChildProfileStep: View {
    let onSubmit: (PairingNewChildProfile) -> Void

    @State private var name = ""
    @State private var birthYear = ""

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(spacing: 20) {
            Text("Who's using this device?")
                .font(.title2.bold())

            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder)
            TextField("Birth year (optional)", text: $birthYear)
                .keyboardType(.numberPad)
                .textFieldStyle(.roundedBorder)

            Button("Continue") {
                onSubmit(PairingNewChildProfile(
                    displayName: trimmedName,
                    birthYear: Int(birthYear),
                    gender: nil
                ))
            }
            .buttonStyle(.borderedProminent)
            .disabled(trimmedName.isEmpty)
        }
        .padding()
    }
}
