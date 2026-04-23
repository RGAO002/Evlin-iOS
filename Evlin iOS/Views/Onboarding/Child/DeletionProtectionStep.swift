import SwiftUI
import ManagedSettings

struct DeletionProtectionStep: View {
    let onContinue: () -> Void

    @State private var applied = false

    var body: some View {
        VStack(spacing: 20) {
            Text("Protect Evlin from deletion")
                .font(.evHeadlineLarge)
                .padding(.top, 40)
            Text("Evlin will now block itself from being deleted. Even if Liam knows the device passcode, they won't be able to uninstall Evlin unless you turn this off.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal)
            Spacer()
            if applied {
                Label("Evlin is now protected from deletion.", systemImage: "checkmark.shield.fill")
                    .foregroundStyle(.green)
                Button(action: onContinue) {
                    Text("Continue").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            } else {
                Button {
                    enable()
                } label: {
                    Text("Enable Protection").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
        }
        .padding()
    }

    private func enable() {
        let store = ManagedSettingsStore()
        store.application.denyAppRemoval = true
        applied = true
    }
}
