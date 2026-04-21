import SwiftUI

struct ProfileCard: View {
    let child: ChildProfile
    var action: () -> Void = {}

    @State private var ping: Bool = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .center, spacing: 16) {
                EvlinAvatarView(url: child.avatarURL, name: child.name, size: 56, status: child.status)

                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Text(child.name)
                            .font(.custom("Manrope", size: 17).weight(.heavy))
                            .tracking(-0.2)
                            .foregroundStyle(Color.evPrimary)
                        if child.status == .unlocked {
                            HStack(spacing: 5) {
                                ZStack {
                                    Circle()
                                        .fill(Color.evSecondary.opacity(0.6))
                                        .frame(width: 8, height: 8)
                                        .scaleEffect(ping ? 1.8 : 1.0)
                                        .opacity(ping ? 0 : 0.6)
                                    Circle()
                                        .fill(Color.evSecondary)
                                        .frame(width: 8, height: 8)
                                }
                                Text("UNLOCKED")
                                    .font(.custom("Inter", size: 9).weight(.heavy))
                                    .tracking(1.5)
                                    .foregroundStyle(Color.evSecondary)
                            }
                        } else {
                            Text("QUIET TIME")
                                .font(.custom("Inter", size: 9).weight(.heavy))
                                .tracking(1.5)
                                .foregroundStyle(Color.evOnSurfaceVariant)
                        }
                    }

                    Text(child.subtitle)
                        .font(.custom("Inter", size: 12))
                        .foregroundStyle(Color.evOnSurfaceVariant)
                        .lineLimit(1)

                    // progress bar
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.evSecondaryContainer).frame(height: 5)
                            Capsule().fill(Color.evSecondary)
                                .frame(width: max(6, geo.size.width * child.timePct), height: 5)
                        }
                    }
                    .frame(height: 5)

                    Text("\(child.timeLeft) left today")
                        .font(.custom("Inter", size: 11).weight(.bold))
                        .foregroundStyle(Color.evSecondary)
                }

                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.evOutline)
            }
            .padding(18)
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(Color.evSurfaceContainerLowest)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(Color.evOutlineVariant.opacity(0.4), lineWidth: 1)
            )
            .evShadow(.premium)
        }
        .buttonStyle(.plain)
        .onAppear {
            if child.status == .unlocked {
                withAnimation(.easeOut(duration: 1.6).repeatForever(autoreverses: false)) {
                    ping = true
                }
            }
        }
    }
}

#Preview {
    VStack(spacing: 14) {
        ProfileCard(child: .liam)
        ProfileCard(child: .maya)
        ProfileCard(child: .emma)
    }
    .padding()
    .background(Color.evSurface)
}
