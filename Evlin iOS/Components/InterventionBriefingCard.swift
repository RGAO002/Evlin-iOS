import SwiftUI

// MARK: - Real-Time Intervention Briefing Card
// Appears inline in Chat when Evlin detects a pattern worth flagging.
// Style inspired by AgentReasoningCard but amber-coded for caution.

struct InterventionBriefingModel: Identifiable {
    let id = UUID()
    let childName: String
    let childEmoji: String
    let signal: String            // short headline — "Continuous YouTube"
    let detail: String            // body sentence
    let detectedAt: Date          // for timestamp
    let primaryActionTitle: String
    let secondaryActionTitle: String?
}

struct InterventionBriefingCard: View {
    let model: InterventionBriefingModel
    var onPrimary: () -> Void = {}
    var onSecondary: () -> Void = {}
    var onDismiss: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.lg) {
            header
            body_
            actions
        }
        .padding(Spacing.xl)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            LinearGradient(
                colors: [
                    Color.evTertiaryFixed,
                    Color.evTertiaryFixed.opacity(0.5)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .overlay(
            HStack {
                Rectangle()
                    .fill(Color.evTertiaryContainer)
                    .frame(width: 4)
                Spacer()
            }
        )
        .overlay(
            RoundedRectangle(cornerRadius: CornerRadius.lg, style: .continuous)
                .stroke(Color.evTertiaryContainer.opacity(0.25), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: CornerRadius.lg, style: .continuous))
        .shadow(color: Color.evTertiaryContainer.opacity(0.15), radius: 10, x: 0, y: 4)
    }

    // MARK: - Header row (label + timestamp + dismiss)

    private var header: some View {
        HStack(spacing: Spacing.md) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(Color.evTertiaryContainer)

            Text("Real-Time Briefing")
                .font(.evLabelMedium)
                .foregroundStyle(Color.evTertiary)
                .evLabelStyle()

            Spacer()

            Text(timestampString)
                .evTimestampStyle()
                .foregroundStyle(Color.evTertiary.opacity(0.55))

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Color.evTertiary.opacity(0.45))
                    .padding(5)
                    .background(Circle().fill(Color.white.opacity(0.4)))
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Body (child + signal + detail)

    private var body_: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            HStack(spacing: Spacing.lg) {
                // Child avatar
                ZStack {
                    Circle()
                        .fill(Color.white)
                        .frame(width: 40, height: 40)
                        .overlay(
                            Circle().stroke(Color.evTertiaryContainer.opacity(0.3), lineWidth: 1)
                        )
                    Text(model.childEmoji)
                        .font(.system(size: 22))
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(model.childName)
                        .font(.custom("Manrope", size: 15).weight(.bold))
                        .foregroundStyle(Color.evTertiary)

                    Text(model.signal)
                        .font(.evLabelLarge)
                        .foregroundStyle(Color.evTertiary.opacity(0.75))
                }
            }

            Text(model.detail)
                .font(.evBodySmall)
                .foregroundStyle(Color.evOnSurfaceVariant)
                .lineSpacing(3)
                .padding(.top, 2)
        }
    }

    // MARK: - Action buttons

    private var actions: some View {
        HStack(spacing: Spacing.md) {
            Button(action: onPrimary) {
                Text(model.primaryActionTitle)
                    .font(.evLabelLarge)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: CornerRadius.md, style: .continuous)
                            .fill(Color.evPrimary)
                    )
            }
            .buttonStyle(.plain)

            if let secondary = model.secondaryActionTitle {
                Button(action: onSecondary) {
                    Text(secondary)
                        .font(.evLabelLarge)
                        .foregroundStyle(Color.evTertiary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(
                            RoundedRectangle(cornerRadius: CornerRadius.md, style: .continuous)
                                .stroke(Color.evTertiary.opacity(0.3), lineWidth: 1)
                                .background(
                                    RoundedRectangle(cornerRadius: CornerRadius.md, style: .continuous)
                                        .fill(Color.white.opacity(0.4))
                                )
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.top, Spacing.xs)
    }

    private var timestampString: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"
        return "Detected \(formatter.string(from: model.detectedAt))"
    }
}

// MARK: - Preview

#Preview {
    VStack(spacing: 20) {
        InterventionBriefingCard(
            model: InterventionBriefingModel(
                childName: "Liam",
                childEmoji: "🦊",
                signal: "Continuous YouTube use",
                detail: "Liam has been on YouTube for 45 minutes straight, past his weekday screen budget. Consider stepping in before it rolls into homework time.",
                detectedAt: Date(),
                primaryActionTitle: "Lock for 30 min",
                secondaryActionTitle: "Dismiss"
            )
        )
    }
    .padding()
    .background(Color.evSurface)
}
