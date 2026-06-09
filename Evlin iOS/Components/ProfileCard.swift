import SwiftUI

struct ProfileCard: View {
    let child: ChildProfile
    var action: () -> Void = {}

    @State private var pressed: Bool = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 16) {
                EvlinAvatarView(url: child.avatarURL, name: child.name, size: 56, status: child.status)

                VStack(alignment: .leading, spacing: 8) {
                    // Line 1: Name · age X
                    HStack(spacing: 6) {
                        Text(child.name)
                            .font(.custom("Manrope", size: 17).weight(.heavy))
                            .tracking(-0.2)
                            .foregroundStyle(Color.evPrimary)
                        Text("· age \(child.age)")
                            .font(.custom("Inter", size: 13))
                            .foregroundStyle(Color.evOnSurfaceVariant)
                    }

                    // Line 2: real device presence (online / last seen / offline).
                    // No fabricated "UNLOCKED · 2h" or fake progress bar — the
                    // backend has no live time-budget field yet (spec B / P1).
                    if let line = child.deviceStatusLine {
                        HStack(spacing: 6) {
                            Circle()
                                .fill(line == "Online" ? Color.evSecondary : Color.evOutline)
                                .frame(width: 8, height: 8)
                            Text(line.uppercased())
                                .font(.custom("Inter", size: 10).weight(.heavy))
                                .tracking(1.4)
                                .foregroundStyle(line == "Online" ? Color.evSecondary : Color.evOnSurfaceVariant)
                        }
                    }

                    // Line 4: subtitle
                    Text(child.subtitle)
                        .font(.custom("Inter", size: 12))
                        .foregroundStyle(Color.evOnSurfaceVariant)
                        .lineLimit(1)
                }

                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.evOutline)
                    .padding(.top, 4)
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
            .shadow(
                color: .black.opacity(pressed ? 0.08 : 0.04),
                radius: pressed ? 40 : 30,
                x: 0,
                y: pressed ? 20 : 10
            )
            .scaleEffect(pressed ? 1.01 : 1.0)
            .animation(.easeOut(duration: 0.18), value: pressed)
        }
        .buttonStyle(.plain)
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in pressed = true }
                .onEnded { _ in pressed = false }
        )
    }
}
