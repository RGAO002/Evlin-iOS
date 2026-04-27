import SwiftUI

/// Top-of-screen banner that auto-dismisses after 5s. See HTML 2106-2127.
struct NotificationBanner: View {
    let title: String
    let message: String
    let avatarURL: String?
    var onDismiss: () -> Void = {}

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.evPrimary)
                Image(systemName: "sparkles")
                    .font(.system(size: 20))
                    .foregroundStyle(.white)
            }
            .frame(width: 40, height: 40)

            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text("EVLIN")
                        .font(.custom("Inter", size: 12).weight(.heavy))
                        .tracking(0.6)
                        .foregroundStyle(Color.evOnSurfaceVariant)
                    Spacer()
                    Text("now")
                        .font(.custom("Inter", size: 11))
                        .foregroundStyle(Color.evOutline)
                }
                Text(title)
                    .font(.custom("Manrope", size: 14).weight(.heavy))
                    .foregroundStyle(Color.evPrimary)
                Text(message)
                    .font(.custom("Inter", size: 13))
                    .foregroundStyle(Color.evOnSurface)
                    .lineSpacing(2)
                    .lineLimit(2)
            }

            if let urlStr = avatarURL, let url = URL(string: urlStr) {
                AsyncImage(url: url) { phase in
                    if let img = phase.image {
                        img.resizable().scaledToFill()
                    } else {
                        Rectangle().fill(Color.evSurfaceContainerLow)
                    }
                }
                .frame(width: 40, height: 40)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Color.evChildLiam, lineWidth: 2)
                )
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(.ultraThinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(Color.white.opacity(0.6), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.16), radius: 32, y: 8)
        .padding(.horizontal, 12)
        .onTapGesture { onDismiss() }
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) {
                onDismiss()
            }
        }
    }
}
