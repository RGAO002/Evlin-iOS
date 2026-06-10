import SwiftUI

struct ProfileCard: View {
    let child: ChildProfile
    var action: () -> Void = {}

    @State private var ping: Bool = false
    @State private var pressed: Bool = false

    /// HP-11: the card's status line + progress bar render only from REAL
    /// data. Priority: the polled live entry (paired child) wins, then a
    /// profile that explicitly carries values (fixtures/previews). Backend
    /// children without a paired device resolve to nil → those two rows
    /// are hidden; everything else on the card is untouched.
    private var live: ChildLiveStatus? {
        if let polled = ChildLiveStatusStore.shared.byChildID[child.id] {
            return polled
        }
        guard child.hasLiveStatus else { return nil }
        return ChildLiveStatus(
            status: child.status,
            timeLeft: child.timeLeft,
            timePct: child.timePct
        )
    }

    private func displayTimeLeft(_ live: ChildLiveStatus) -> String {
        let trimmed = live.timeLeft.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "0m" : trimmed
    }

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 16) {
                EvlinAvatarView(url: child.avatarURL, name: child.name, size: 56, status: live?.status)

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

                    // Line 2: status + time (single line). Hidden entirely
                    // when there is no live data for this child (HP-11) —
                    // the design below is unchanged when data exists.
                    if let live {
                        HStack(spacing: 6) {
                            if live.status == .unlocked {
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
                                Text("UNLOCKED · \(displayTimeLeft(live)) left")
                                    .font(.custom("Inter", size: 10).weight(.heavy))
                                    .tracking(1.4)
                                    .foregroundStyle(Color.evSecondary)
                                    .fixedSize(horizontal: true, vertical: false)
                            } else {
                                Text("QUIET TIME")
                                    .font(.custom("Inter", size: 10).weight(.heavy))
                                    .tracking(1.4)
                                    .foregroundStyle(Color.evOnSurfaceVariant)
                            }
                        }

                        // Line 3: progress bar — gray (flat) for locked, green (filled) for unlocked
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule()
                                    .fill(live.status == .unlocked
                                          ? Color.evSecondaryContainer
                                          : Color.evSurfaceContainerHigh)
                                    .frame(height: 5)
                                if live.status == .unlocked {
                                    Capsule()
                                        .fill(Color.evSecondary)
                                        .frame(width: max(6, geo.size.width * live.timePct), height: 5)
                                }
                            }
                        }
                        .frame(height: 5)
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
        .onAppear { syncPing(for: live?.status) }
        // Live data can arrive AFTER the card appears (first poll round) or
        // flip while it's visible — re-arm the ping animation so the
        // unlocked dot keeps its existing pulse in both cases.
        .onChange(of: live?.status) { _, newStatus in syncPing(for: newStatus) }
    }

    private func syncPing(for status: ChildProfile.Status?) {
        if status == .unlocked {
            guard !ping else { return }
            withAnimation(.easeOut(duration: 1.6).repeatForever(autoreverses: false)) {
                ping = true
            }
        } else {
            // Dot is not rendered — reset silently so a later unlock
            // restarts the repeatForever animation from a clean state.
            var t = Transaction()
            t.disablesAnimations = true
            withTransaction(t) { ping = false }
        }
    }
}
