import SwiftUI

struct ChatInputBar: View {
    @Binding var text: String
    var onSend: () -> Void

    var body: some View {
        HStack(spacing: Spacing.lg) {
            // Add button
            Button {
                // TODO: attachment menu
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(Color.evOutline)
                    .frame(width: 36, height: 36)
                    .background(
                        Circle()
                            .fill(Color.evSurfaceContainerHigh)
                    )
            }

            // Text field
            TextField("Consult Evlin on child development...", text: $text)
                .font(.evBodyMedium)
                .foregroundStyle(Color.evOnSurface)
                .tint(Color.evPrimary)

            // Send button
            Button(action: onSend) {
                HStack(spacing: 6) {
                    Text("SEND")
                        .font(.system(size: 11, weight: .bold))
                        .tracking(1.5)

                    Image(systemName: "arrowtriangle.right.fill")
                        .font(.system(size: 10))
                }
                .foregroundStyle(Color.evOnPrimary)
                .padding(.horizontal, Spacing.xl)
                .padding(.vertical, Spacing.lg)
                .background(
                    RoundedRectangle(cornerRadius: CornerRadius.lg)
                        .fill(text.isEmpty ? Color.evPrimary.opacity(0.4) : Color.evPrimary)
                )
            }
            .disabled(text.isEmpty)
        }
        .padding(.horizontal, Spacing.xl)
        .padding(.vertical, Spacing.lg)
        .background(
            RoundedRectangle(cornerRadius: CornerRadius.xxl)
                .fill(Color.evSurfaceContainerLowest)
                .overlay(
                    RoundedRectangle(cornerRadius: CornerRadius.xxl)
                        .stroke(Color.evOutlineVariant.opacity(0.2), lineWidth: 1)
                )
                .evChatInputShadow()
        )
        .padding(.horizontal, Spacing.xl)
        .padding(.bottom, Spacing.md)
    }
}
