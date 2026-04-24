import SwiftUI

struct ProtectionLevelStep: View {
    @Binding var mode: String
    let onContinue: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.section) {
            VStack(alignment: .leading, spacing: Spacing.lg) {
                Text("Choose setup path")
                    .font(.evHeadlineLarge)
                    .foregroundStyle(Color.evPrimary)
                Text("Maximum is the product experience we want: parent picks the child's apps from the parent phone. Standard is a fallback for testing or families who skip Child Apple Account setup.")
                    .font(.evBodyMedium)
                    .foregroundStyle(Color.evOnSurfaceVariant)
            }
            .padding(.top, Spacing.section)

            VStack(spacing: Spacing.lg) {
                card(
                    title: "Maximum",
                    subtitle: "Recommended",
                    bullets: [
                        "Parent phone can open Apple's picker and see the child's apps.",
                        "Saved Lists can be created from the parent phone.",
                        "Requires the child phone to use a Child Apple Account in Family Sharing.",
                        "Uses parent-approved .child Screen Time authorization.",
                    ],
                    selected: mode == "max",
                    onTap: { mode = "max" }
                )

                card(
                    title: "Standard",
                    subtitle: "Skip for now",
                    bullets: [
                        "No Child Apple Account required.",
                        "Picker only works on the child phone.",
                        "Good for one-device testing and early fallback.",
                        "Parent phone will not see the child's app list.",
                    ],
                    selected: mode == "std",
                    onTap: { mode = "std" }
                )
            }

            Spacer()

            Button(action: onContinue) {
                Text(mode == "max" ? "Continue with Maximum" : "Continue with Standard")
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
        .onAppear {
            if mode.isEmpty { mode = "max" }
        }
    }

    private func card(
        title: String,
        subtitle: String,
        bullets: [String],
        selected: Bool,
        onTap: @escaping () -> Void
    ) -> some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: Spacing.lg) {
                HStack(spacing: Spacing.lg) {
                    Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                        .font(.system(size: 20))
                        .foregroundStyle(Color.evPrimary)

                    VStack(alignment: .leading, spacing: Spacing.xs) {
                        Text(title)
                            .font(.evLabelLarge)
                            .foregroundStyle(Color.evPrimary)
                        Text(subtitle)
                            .font(.evBodySmall)
                            .foregroundStyle(Color.evOnSurfaceVariant)
                    }

                    Spacer()
                }

                VStack(alignment: .leading, spacing: Spacing.md) {
                    ForEach(bullets, id: \.self) { bulletText in
                        HStack(alignment: .top, spacing: Spacing.md) {
                            Circle()
                                .fill(Color.evOutline)
                                .frame(width: 4, height: 4)
                                .padding(.top, 7)
                            Text(bulletText)
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
