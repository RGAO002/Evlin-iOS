import SwiftUI

struct SetPasscodeStep: View {
    let onContinue: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Set Screen Time Passcode")
                .font(.evHeadlineLarge)
                .padding(.top, 40)
            Text("On Liam's phone:\n\n1. Open Settings → Screen Time\n2. Lock Screen Time Settings\n3. Set a 4-digit passcode Liam doesn't know\n\nThis prevents Liam from changing Screen Time settings. Evlin's own deletion protection is automatic — no extra step needed.")
                .foregroundStyle(.secondary)
            Button("Open Screen Time Settings") {
                Task { await ScreenTimeManager.shared.openScreenTimeSettings() }
            }
            .buttonStyle(.bordered)
            Spacer()
            Button(action: onContinue) {
                Text("I've set the passcode").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .padding()
    }
}
