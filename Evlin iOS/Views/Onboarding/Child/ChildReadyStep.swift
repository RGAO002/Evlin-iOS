import SwiftUI

struct ChildReadyStep: View {
    @AppStorage("onboardingComplete") private var onboardingComplete = false
    let onEnter: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 80))
                .foregroundStyle(.green)
            Text("All set!")
                .font(.evHeadlineLarge)
            Text("Waiting for commands from your parent's Evlin.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal)
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
