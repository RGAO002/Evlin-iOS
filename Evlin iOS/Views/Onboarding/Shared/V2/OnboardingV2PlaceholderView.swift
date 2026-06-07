import SwiftUI

/// SCAFFOLD-ONLY placeholder for the onboarding v2 flow.
///
/// Every v2 screen renders one of these so a human can tap through the entire
/// parent + kid sequence end-to-end before any real per-screen UI exists.
/// It is intentionally generic and LABELED: it shows the screen's title,
/// subtitle/purpose (copied from the v2 mockup), the phase + step counter so
/// each screen is recognizable against the mockup, plus a primary "Continue"
/// button and a "Back" affordance that drive the coordinator.
///
/// Visual polish per-screen comes LATER — this is the compiling, navigable
/// skeleton only.
struct OnboardingV2PlaceholderView: View {

    enum Side {
        case parent
        case child

        var label: String { self == .parent ? "PARENT DEVICE" : "KID DEVICE" }
        var accent: Color { self == .parent ? .evPrimary : .evSecondary }
        var icon: String { self == .parent ? "person.fill.checkmark" : "person.fill" }
    }

    /// "PARENT" or "KID" — drives the accent color + footer label.
    let side: Side
    /// e.g. "2 · Accounts" — the mockup's phase grouping.
    let phase: String
    /// 1-based index of this screen within the side's v2 sequence.
    let stepIndex: Int
    /// Total screens in the side's v2 sequence (for "Step 3 of 9").
    let stepTotal: Int
    /// The mockup screen title (recognizable vs the HTML prototype).
    let title: String
    /// One-line purpose / subtitle from the mockup.
    let subtitle: String
    /// Optional extra note (e.g. "polls /family/pairing-status").
    var note: String? = nil
    /// Label for the primary advance button. Defaults to "Continue".
    var primaryLabel: String = "Continue"

    /// Advance the coordinator to the next v2 step.
    let onContinue: () -> Void
    /// Step back in the v2 chain. Nil hides the Back affordance (first screen).
    var onBack: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: Spacing.section) {

            // Top: which device + where we are in the flow.
            VStack(spacing: Spacing.md) {
                HStack(spacing: Spacing.md) {
                    Image(systemName: side.icon)
                        .font(.system(size: 13, weight: .bold))
                    Text(side.label)
                        .font(.evLabelMedium)
                }
                .foregroundStyle(side.accent)
                .padding(.vertical, Spacing.sm)
                .padding(.horizontal, Spacing.lg)
                .background(
                    Capsule().fill(side.accent.opacity(0.10))
                )

                Text("\(phase)  ·  Step \(stepIndex) of \(stepTotal)")
                    .font(.evCaption)
                    .foregroundStyle(Color.evOnSurfaceVariant)
            }
            .padding(.top, Spacing.section)

            Spacer()

            // Center: the screen identity (title + purpose).
            VStack(spacing: Spacing.lg) {
                Circle()
                    .fill(side.accent)
                    .frame(width: 56, height: 56)
                    .overlay(
                        Image(systemName: "rectangle.dashed")
                            .font(.system(size: 24, weight: .bold))
                            .foregroundStyle(Color.evOnPrimary)
                    )

                Text(title)
                    .font(.evHeadlineMedium)
                    .foregroundStyle(Color.evPrimary)
                    .multilineTextAlignment(.center)

                Text(subtitle)
                    .font(.evBodyMedium)
                    .foregroundStyle(Color.evOnSurfaceVariant)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, Spacing.xl)

                if let note {
                    Text(note)
                        .font(.evBodySmall)
                        .foregroundStyle(Color.evOutline)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, Spacing.xl)
                }

                Text("PLACEHOLDER — visual design lands later")
                    .font(.evLabelSmall)
                    .foregroundStyle(Color.evOutline)
                    .padding(.top, Spacing.md)
            }

            Spacer()

            // Bottom: advance + back.
            VStack(spacing: Spacing.lg) {
                Button(action: onContinue) {
                    Text(primaryLabel)
                        .font(.evLabelLarge)
                        .frame(maxWidth: .infinity)
                }
                .foregroundStyle(Color.evOnPrimary)
                .padding(.vertical, Spacing.lg)
                .background(
                    RoundedRectangle(cornerRadius: CornerRadius.md)
                        .fill(side.accent)
                )

                if let onBack {
                    Button(action: onBack) {
                        Text("Back")
                            .font(.evLabelLarge)
                            .foregroundStyle(Color.evOnSurfaceVariant)
                    }
                }
            }
            .padding(.horizontal, Spacing.xl)
        }
        .padding(Spacing.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.evSurface)
    }
}
