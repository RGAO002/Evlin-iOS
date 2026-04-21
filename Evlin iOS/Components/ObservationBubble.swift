import SwiftUI

struct ObservationBubble: View {
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            ZStack {
                Circle().fill(Color.evPrimaryGradient)
                    .frame(width: 28, height: 28)
                Image(systemName: "sparkles")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white)
            }

            Text(text)
                .font(.custom("Inter", size: 14))
                .foregroundStyle(Color.evOnSurface)
                .lineSpacing(3)
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Color.evSurfaceContainerLowest)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(Color.evOutlineVariant.opacity(0.4), lineWidth: 1)
                )
        }
    }
}
