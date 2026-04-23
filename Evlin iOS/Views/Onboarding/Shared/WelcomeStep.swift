import SwiftUI

struct WelcomeStep: View {
    let onContinue: () -> Void
    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            Circle()
                .fill(Color.evPrimary)
                .frame(width: 80, height: 80)
                .overlay(
                    Image(systemName: "shield.checkered")
                        .font(.system(size: 36, weight: .bold))
                        .foregroundStyle(Color.evOnPrimary)
                )
            VStack(spacing: 12) {
                Text("Welcome to Evlin")
                    .font(.evHeadlineLarge)
                    .foregroundStyle(Color.evPrimary)
                Text("The Informed Sentinel")
                    .font(.evHeadlineSmall)
                    .foregroundStyle(Color.evOnPrimaryContainer)
                Text("AI-powered parental control. Setup takes about 2 minutes.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)
            }
            Spacer()
            Button(action: onContinue) {
                Text("Continue").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.horizontal)
        }
        .padding()
    }
}
