import SwiftUI

struct SignInOnChildStep: View {
    let onContinue: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Sign In on Liam's Phone")
                .font(.evHeadlineLarge)
                .padding(.top, 40)
            Text("On Liam's phone:\n\n1. Sign out of the existing Apple ID (if any)\n2. Sign in with the Child Apple ID you just created\n3. Return to Evlin — it's already running there in child mode")
                .foregroundStyle(.secondary)
            Spacer()
            Button(action: onContinue) {
                Text("I've signed in on Liam's phone").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .padding()
    }
}
