import SwiftUI

// MARK: - New tab structure (per Stitch redesign, Apr 16)
// Home / Calendar / [Evlin — brand chat button] / Library / Insights
// The Chat tab sits inline in the bar with a colored circle icon and the
// "Evlin" wordmark as its label.

enum EvlinTab: String, CaseIterable {
    case home = "Home"
    case calendar = "Calendar"
    case chat = "Evlin"          // label shown in the bar
    case library = "Library"
    case insights = "Insights"

    var icon: String {
        switch self {
        case .home: return "house"
        case .calendar: return "calendar"
        case .chat: return "bubble.left"
        case .library: return "books.vertical"
        case .insights: return "chart.line.uptrend.xyaxis"
        }
    }

    var filledIcon: String {
        switch self {
        case .home: return "house.fill"
        case .calendar: return "calendar"
        case .chat: return "bubble.left.fill"
        case .library: return "books.vertical.fill"
        case .insights: return "chart.line.uptrend.xyaxis"
        }
    }
}

struct EvlinTabBar: View {
    @Binding var selectedTab: EvlinTab

    var body: some View {
        HStack(spacing: 0) {
            ForEach(EvlinTab.allCases, id: \.self) { tab in
                if tab == .chat {
                    chatItem
                } else {
                    tabItem(tab)
                }
            }
        }
        .padding(.horizontal, Spacing.sm)
        .padding(.top, 0)
        .padding(.bottom, Spacing.sm)
        .background(
            Color.evSurfaceContainerLowest
                .ignoresSafeArea(edges: .bottom)
        )
    }

    // MARK: - Standard side tab

    private func tabItem(_ tab: EvlinTab) -> some View {
        let isActive = selectedTab == tab

        return Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                selectedTab = tab
            }
        } label: {
            VStack(spacing: 4) {
                // Top selection indicator — same color as icon/label when active
                Capsule()
                    .fill(isActive ? Color.evPrimary : Color.clear)
                    .frame(width: 28, height: 3)

                Image(systemName: isActive ? tab.filledIcon : tab.icon)
                    .font(.system(size: 19))
                    .frame(width: 26, height: 26)
                    .foregroundStyle(
                        isActive ? Color.evPrimary : Color.evOnSurface.opacity(0.45)
                    )

                Text(tab.rawValue)
                    .font(.system(size: 10, weight: .semibold))
                    .textCase(.uppercase)
                    .tracking(0.5)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .foregroundStyle(
                        isActive ? Color.evPrimary : Color.evOnSurface.opacity(0.45)
                    )
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Center "Evlin" chat tab
    // Large circle that's half above the tab bar top edge, half inside.
    // Label stays aligned with the other tab labels at the bottom.

    private var chatItem: some View {
        let isActive = selectedTab == .chat

        return Button {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.72)) {
                selectedTab = .chat
            }
        } label: {
            VStack(spacing: 4) {
                // Matches the selection-indicator capsule height in side tabs
                // so "EVLIN" stays vertically aligned with other labels.
                Color.clear
                    .frame(width: 28, height: 3)

                // Icon slot — same layout size as siblings (26×26) so the
                // label below aligns with other tabs. The actual circle is
                // drawn as an overlay at 56pt and shifted up so half of it
                // overflows above the tab bar's top edge.
                Color.clear
                    .frame(width: 26, height: 26)
                    .overlay(
                        ZStack {
                            Circle()
                                .fill(
                                    LinearGradient(
                                        colors: [
                                            Color.evSecondary,
                                            Color(hex: 0x155C1D)
                                        ],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    )
                                )
                                .frame(width: 56, height: 56)
                                .overlay(
                                    Circle()
                                        .stroke(Color.white.opacity(0.18), lineWidth: 1.5)
                                )
                                .shadow(
                                    color: Color.evSecondary.opacity(isActive ? 0.5 : 0.3),
                                    radius: isActive ? 10 : 5,
                                    x: 0,
                                    y: 4
                                )
                                .scaleEffect(isActive ? 1.06 : 1.0)

                            Image(systemName: isActive ? EvlinTab.chat.filledIcon : EvlinTab.chat.icon)
                                .font(.system(size: 22, weight: .semibold))
                                .foregroundStyle(.white)
                        }
                        .offset(y: -22)   // push up so ~half sits above the bar
                    )

                Text(EvlinTab.chat.rawValue)     // "Evlin"
                    .font(.system(size: 10, weight: .semibold))
                    .textCase(.uppercase)
                    .tracking(0.5)
                    .lineLimit(1)
                    .foregroundStyle(
                        isActive ? Color.evSecondary : Color.evOnSurface.opacity(0.45)
                    )
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Open Evlin Chat")
    }
}

#Preview {
    @Previewable @State var tab: EvlinTab = .chat
    return VStack {
        Spacer()
        EvlinTabBar(selectedTab: $tab)
    }
    .background(Color.evSurface)
}
