import SwiftUI

struct DoneStep: View {
    @AppStorage("onboardingComplete") private var onboardingComplete = false
    let onEnter: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "sparkles")
                .font(.system(size: 80))
                .foregroundStyle(Color.evPrimary)
            Text("Liam is protected.")
                .font(.evHeadlineLarge)
            Text("Open Chat to send your first command.")
                .foregroundStyle(.secondary)
            Spacer()
            Button {
                onboardingComplete = true
                onEnter()
            } label: {
                Text("Enter Evlin").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding()
        }
    }
}
