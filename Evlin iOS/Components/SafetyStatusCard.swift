import SwiftUI

/// Safety status card embedded in chat after safety queries
/// Source: safety_assurance_briefing — the "Physical Safety Confirmed" card
struct SafetyStatusCard: View {
    let childName: String

    var body: some View {
        VStack(spacing: Spacing.xxxl) {
            // Header
            HStack {
                HStack(spacing: Spacing.lg) {
                    Circle()
                        .fill(Color.evSecondary)
                        .frame(width: 8, height: 8)

                    Text("Physical Safety Confirmed")
                        .font(.evHeadlineSmall)
                        .foregroundStyle(Color.evPrimary)
                }
                Spacer()
                Image(systemName: "checkmark.shield.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(Color.evSecondary)
            }

            // Location
            ZStack {
                RoundedRectangle(cornerRadius: CornerRadius.lg)
                    .fill(Color.evSurfaceContainer)
                    .frame(height: 140)

                VStack(spacing: Spacing.md) {
                    Image(systemName: "location.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(Color.evPrimary)

                    Text("AT HOME (LIVING ROOM)")
                        .font(.evLabelMedium)
                        .foregroundStyle(Color.evPrimary)
                        .evLabelStyle()
                }
                .padding(.horizontal, Spacing.xl)
                .padding(.vertical, Spacing.lg)
                .background(
                    RoundedRectangle(cornerRadius: CornerRadius.xl)
                        .fill(Color.white.opacity(0.9))
                        .shadow(color: .black.opacity(0.08), radius: 8, y: 3)
                )
            }

            // Status grid
            HStack(spacing: Spacing.lg) {
                statusIndicator(icon: "sensor.fill", label: "Device State", value: "Stationary & Logged")
                statusIndicator(icon: "ear.fill", label: "Acoustics", value: "Safe & Present")
            }
        }
        .padding(Spacing.xxl)
        .background(
            RoundedRectangle(cornerRadius: CornerRadius.xl)
                .fill(Color.evSurfaceContainerLowest)
        )
        .evAmbientShadow()
    }

    private func statusIndicator(icon: String, label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            HStack(spacing: Spacing.md) {
                Image(systemName: icon)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.evSecondary)
                Text(label)
                    .font(.evLabelSmall)
                    .foregroundStyle(Color.evOnSurfaceVariant)
                    .textCase(.uppercase)
            }
            Text(value)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.evPrimary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Spacing.lg)
        .background(Color.evSurfaceContainerLow)
        .overlay(
            HStack {
                Rectangle().fill(Color.evSecondary.opacity(0.4)).frame(width: 4)
                Spacer()
            }
        )
        .clipShape(RoundedRectangle(cornerRadius: CornerRadius.md))
    }
}
