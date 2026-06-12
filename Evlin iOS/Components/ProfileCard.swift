import SwiftUI

struct ProfileCard: View {
    let child: ChildProfile
    var action: () -> Void = {}

    @State private var ping: Bool = false
    @State private var pressed: Bool = false

    private var displayTimeLeft: String {
        let trimmed = child.timeLeft.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "2h" : trimmed
    }

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

                    // Line 2: status + time (single line)
                    HStack(spacing: 6) {
                        if child.status == .unlocked {
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
                            Text("UNLOCKED · \(displayTimeLeft) left")
                                .font(.custom("Inter", size: 10).weight(.heavy))
                                .tracking(1.4)
                                .foregroundStyle(Color.evSecondary)
                                .fixedSize(horizontal: true, vertical: false)
                        } else {
                            Circle()
                                .fill(Color.evError)
                                .frame(width: 8, height: 8)
                            Text("LOCKED")
                                .font(.custom("Inter", size: 10).weight(.heavy))
                                .tracking(1.4)
                                .foregroundStyle(Color.evError)
                        }
                    }

                    // Line 3: progress bar — red (locked) or green (unlocked).
                    // Fill width = remaining-time fraction (child.timePct).
                    // timePct is a hardcoded 1.0 today, so it reads full until
                    // real remaining-time data is wired in.
                    GeometryReader { geo in
                        let isLocked = child.status != .unlocked
                        ZStack(alignment: .leading) {
                            Capsule()
                                .fill(isLocked
                                      ? Color.evErrorContainer
                                      : Color.evSecondaryContainer)
                                .frame(height: 5)
                            Capsule()
                                .fill(isLocked ? Color.evError : Color.evSecondary)
                                .frame(width: max(6, geo.size.width * child.timePct), height: 5)
                        }
                    }
                    .frame(height: 5)

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
        .onAppear {
            if child.status == .unlocked {
                withAnimation(.easeOut(duration: 1.6).repeatForever(autoreverses: false)) {
                    ping = true
                }
            }
        }
    }
}
