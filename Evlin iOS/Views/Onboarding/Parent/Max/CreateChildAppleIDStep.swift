import SwiftUI

struct CreateChildAppleIDStep: View {
    let onContinue: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Create a Child Apple ID")
                .font(.evHeadlineLarge)
                .padding(.top, 40)
            Text("On THIS phone:\n\n1. Open Settings → Family\n2. Tap Add Member → Create a Child Account\n3. Follow Apple's prompts (~3 min)")
                .foregroundStyle(.secondary)
            Button("Open Family Settings") {
                Task { await ScreenTimeManager.shared.openScreenTimeSettings() }
            }
            .buttonStyle(.bordered)
            Spacer()
            Button(action: onContinue) {
                Text("I've created the account").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .padding()
    }
}
