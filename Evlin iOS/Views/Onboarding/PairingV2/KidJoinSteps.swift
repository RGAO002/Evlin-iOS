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
    var onBack: (() -> Void)? = nil

    @State private var typedCode = ""

    var body: some View {
        // Same container, scanner and code field the parent's scan screen used
        // — only the direction and the copy change.
        OnboardingV2ScreenContainer(
            embeddedRole: .child,
            phase: "2 · Pair",
            stepIndex: 4,
            stepTotal: childTotal,
            title: "Scan your parent's code",
            subtitle: "Point your camera at the QR on your parent's phone — or type the 6-digit code it shows.",
            content: {
                VStack(spacing: Spacing.lg) {
                    HStack {
                        Spacer(minLength: 0)
                        // The shared scanner handles the permission states and
                        // already points at the typed-code field when the
                        // camera is unavailable.
                        OnboardingV2QRScanner(onScan: { raw in
                            guard let invite = ScannedInvite.parse(raw) else { return }
                            onScanned(invite)
                        })
                        Spacer(minLength: 0)
                    }
                    .frame(maxWidth: .infinity)

                    OnboardingV2CodeField(code: $typedCode)
                        .onChange(of: typedCode) { _, newValue in
                            let digits = newValue.filter(\.isNumber)
                            if digits != newValue { typedCode = digits }
                            if digits.count > 6 { typedCode = String(digits.prefix(6)) }
                            // Six digits is the whole code, so submit on
                            // completion rather than hunting for a button.
                            guard let invite = ScannedInvite.parse(typedCode) else { return }
                            onScanned(invite)
                        }
                }
            },
            footer: {
                if let onBack {
                    OnboardingV2SecondaryButton("Back") { onBack() }
                }
            }
        )
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
