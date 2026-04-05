import SwiftUI

/// Gradient confirmation card shown after a lock command is executed
/// Source: smart_recommendations_briefing — the chat-gradient bubble
struct LockConfirmationCard: View {
    let minutes: Int
    let childName: String

    var body: some View {
        ZStack(alignment: .topTrailing) {
            // Watermark
            Image(systemName: "lock.fill")
                .font(.system(size: 50))
                .foregroundStyle(Color.white.opacity(0.1))
                .padding(Spacing.xl)

            VStack(alignment: .leading, spacing: Spacing.xl) {
                (Text("\(childName)'s device has been restricted. All non-educational applications are locked for the next ")
                + Text("\(minutes) minutes")
                    .foregroundColor(Color.evSecondaryFixed)
                    .bold()
                + Text("."))
                .font(.evBodyLarge)
                .lineSpacing(4)

                // Command Executed badge
                HStack(spacing: Spacing.md) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 12))
                    Text("Command Executed")
                        .font(.system(size: 12, weight: .semibold))
                        .tracking(0.5)
                }
                .foregroundStyle(Color.white)
                .padding(.horizontal, Spacing.lg)
                .padding(.vertical, Spacing.md)
                .background(Capsule().fill(Color.white.opacity(0.1)))
            }
            .padding(Spacing.xxxl)
        }
        .foregroundStyle(Color.white)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: CornerRadius.xl)
                .fill(
                    LinearGradient(
                        colors: [Color.evPrimary, Color.evPrimaryContainer],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        )
    }
}
