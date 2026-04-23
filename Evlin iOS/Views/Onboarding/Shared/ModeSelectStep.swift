import SwiftUI

struct ModeSelectStep: View {
    let onSelect: (OnboardingMode) -> Void

    var body: some View {
        VStack(spacing: 20) {
            Text("Which phone is this?")
                .font(.evHeadlineMedium)
                .padding(.top, 40)
            Text("Evlin runs on both the parent's phone and the child's phone.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal)
            Spacer()
            HStack(spacing: 16) {
                modeCard(title: "I'm the parent", systemImage: "person.fill.checkmark") { onSelect(.parent) }
                modeCard(title: "I'm the child", systemImage: "person.fill") { onSelect(.child) }
            }
            .padding(.horizontal)
            Spacer()
        }
    }

    @ViewBuilder
    private func modeCard(title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 12) {
                Image(systemName: systemImage).font(.system(size: 42)).foregroundStyle(Color.evPrimary)
                Text(title).font(.headline).foregroundStyle(Color.evPrimary)
            }
            .frame(maxWidth: .infinity, minHeight: 180)
            .padding()
            .background(Color.evSurfaceContainer)
            .cornerRadius(16)
        }
        .buttonStyle(.plain)
    }
}
