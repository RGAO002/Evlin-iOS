import SwiftUI

/// Evlin PIN edit gate. First run sets a PIN; later edits require it.
///
/// Biometric unlock is intentionally not used because the child's biometric
/// identity is usually enrolled on the child device. This gate is for parent
/// edits on that device.
struct EvlinPINGateView: View {
    let store: EvlinPINStore
    let onUnlocked: () -> Void
    let onCancel: () -> Void

    @State private var pin = ""
    @State private var confirmPIN = ""
    @State private var error: String?

    private var isFirstRun: Bool {
        !store.isSet()
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(isFirstRun
                         ? "Set a PIN only you know. Your child can't change managed apps without it."
                         : "Enter your Evlin PIN to change managed apps.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section {
                    SecureField("PIN (4-8 digits)", text: $pin)
                        .keyboardType(.numberPad)

                    if isFirstRun {
                        SecureField("Confirm PIN", text: $confirmPIN)
                            .keyboardType(.numberPad)
                    }

                    if let error {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }

                Section {
                    Button(isFirstRun ? "Set PIN" : "Unlock") {
                        submit()
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .navigationTitle("Evlin PIN")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        onCancel()
                    }
                }
            }
        }
    }

    private func submit() {
        error = nil

        if isFirstRun {
            guard pin == confirmPIN else {
                error = "PINs don't match."
                return
            }

            do {
                try store.setPIN(pin)
                onUnlocked()
            } catch EvlinPINStore.PINError.invalidLength {
                error = "PIN must be 4-8 digits."
            } catch {
                self.error = "Couldn't save PIN. Try again."
            }
        } else {
            if store.verify(pin) {
                onUnlocked()
            } else {
                error = "Wrong PIN."
                pin = ""
            }
        }
    }
}
