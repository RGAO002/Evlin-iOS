import SwiftUI

struct ProtectionLevelStep: View {
    @Binding var mode: String   // "max" | "std"
    let onContinue: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Protection level")
                .font(.evHeadlineLarge)
                .padding(.top, 40)

            card(
                title: "Maximum (recommended)",
                bullets: [
                    "Pick Liam's apps from THIS phone (via Family Sharing)",
                    "Evlin cannot be uninstalled",
                    "Requires Child Apple ID (5 min one-time setup)",
                ],
                selected: mode == "max",
                onTap: { mode = "max" }
            )
            card(
                title: "Standard",
                bullets: [
                    "Pick apps on Liam's phone directly",
                    "Evlin still cannot be uninstalled (programmatic protection)",
                    "No extra account — simpler setup",
                ],
                selected: mode == "std",
                onTap: { mode = "std" }
            )

            Spacer()

            Button(action: onContinue) {
                Text("Continue").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .padding()
    }

    @ViewBuilder
    private func card(title: String, bullets: [String], selected: Bool, onTap: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(Color.evPrimary)
                Text(title).font(.headline)
            }
            ForEach(bullets, id: \.self) { b in
                HStack(alignment: .top, spacing: 8) {
                    Text("·").fontWeight(.bold)
                    Text(b).font(.subheadline).foregroundStyle(.secondary)
                }
                .padding(.leading, 24)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(selected ? Color.evPrimaryContainer.opacity(0.35) : Color.evSurfaceContainer)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(selected ? Color.evPrimary : Color.clear, lineWidth: 2)
        )
        .cornerRadius(12)
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
    }
}
