import SwiftUI

struct WhyChildAppleIDStep: View {
    let onContinue: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Why Child Apple ID?")
                .font(.evHeadlineLarge)
                .padding(.top, 40)
            bullet("person.2.fill", "Select your child's apps remotely from YOUR phone.")
            bullet("lock.shield.fill", "Evlin cannot be uninstalled from Liam's phone.")
            bullet("clock.fill", "Set time limits and bedtime without needing Liam's help.")
            bullet("checkmark.seal.fill", "Official Apple Family Sharing — fully compliant.")
            Spacer()
            Button(action: onContinue) {
                Text("Got it — let's set it up").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .padding()
    }

    @ViewBuilder
    private func bullet(_ icon: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(Color.evPrimary)
                .frame(width: 32, height: 32)
            Text(text).font(.subheadline)
        }
    }
}
