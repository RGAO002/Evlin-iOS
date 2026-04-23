import SwiftUI

struct ProtectionLevelStep: View {
    @Binding var mode: String   // "max" | "std"
    let onContinue: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.section) {
            VStack(alignment: .leading, spacing: Spacing.lg) {
                Text("Protection level")
                    .font(.evHeadlineLarge)
                    .foregroundStyle(Color.evPrimary)
                Text("Choose how strictly Evlin should protect itself on the child's phone.")
                    .font(.evBodyMedium)
                    .foregroundStyle(Color.evOnSurfaceVariant)
            }
            .padding(.top, Spacing.section)

            VStack(spacing: Spacing.lg) {
                card(
                    title: "Maximum",
                    showRecommended: true,
                    bullets: [
                        "Pick your child's apps from THIS phone (via Family Sharing)",
                        "Evlin cannot be uninstalled",
                        "Requires Child Apple ID (5 min one-time setup)",
                    ],
                    selected: mode == "max",
                    onTap: { mode = "max" }
                )

                card(
                    title: "Standard",
                    showRecommended: false,
                    bullets: [
                        "Pick apps on the child's phone directly",
                        "Evlin still cannot be uninstalled (programmatic protection)",
                        "No extra account — simpler setup",
                    ],
                    selected: mode == "std",
                    onTap: { mode = "std" }
                )
            }

            Spacer()

            Button(action: onContinue) {
                Text("Continue")
                    .font(.evLabelLarge)
                    .frame(maxWidth: .infinity)
            }
            .foregroundStyle(Color.evOnPrimary)
            .padding(.vertical, Spacing.lg)
            .background(
                RoundedRectangle(cornerRadius: CornerRadius.md)
                    .fill(Color.evPrimary)
            )
        }
        .padding(Spacing.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.evSurface)
    }

    @ViewBuilder
    private func card(title: String, showRecommended: Bool, bullets: [String], selected: Bool, onTap: @escaping () -> Void) -> some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: Spacing.lg) {
                HStack(spacing: Spacing.lg) {
                    Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                        .font(.system(size: 20))
                        .foregroundStyle(Color.evPrimary)
                    Text(title)
                        .font(.evLabelLarge)
                        .foregroundStyle(Color.evPrimary)
                    if showRecommended {
                        Text("RECOMMENDED")
                            .font(.evLabelMedium)
                            .evLabelStyle()
                            .foregroundStyle(Color.evOnPrimary)
                            .padding(.horizontal, Spacing.md)
                            .padding(.vertical, Spacing.xs)
                            .background(
                                Capsule().fill(Color.evPrimary)
                            )
                    }
                    Spacer()
                }

                VStack(alignment: .leading, spacing: Spacing.md) {
                    ForEach(bullets, id: \.self) { b in
                        HStack(alignment: .top, spacing: Spacing.md) {
                            Circle()
                                .fill(Color.evOutline)
                                .frame(width: 4, height: 4)
                                .padding(.top, 7)
                            Text(b)
                                .font(.evBodySmall)
                                .foregroundStyle(Color.evOnSurfaceVariant)
                                .multilineTextAlignment(.leading)
                        }
                    }
                }
                .padding(.leading, Spacing.section)
            }
            .padding(Spacing.xl)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: CornerRadius.xl)
                    .fill(selected ? Color.evPrimaryContainer.opacity(0.35) : Color.evSurfaceContainerLowest)
            )
            .overlay(
                RoundedRectangle(cornerRadius: CornerRadius.xl)
                    .stroke(selected ? Color.evPrimary : Color.evOutlineVariant, lineWidth: selected ? 2 : 1)
            )
        }
        .buttonStyle(.plain)
    }
}
