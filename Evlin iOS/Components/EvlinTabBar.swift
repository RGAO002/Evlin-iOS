import SwiftUI

enum EvlinTab: String, CaseIterable {
    case chat = "Chat"
    case dashboard = "Dashboard"
    case strategy = "Strategy"
    case library = "Library"
    case insights = "Insights"

    var icon: String {
        switch self {
        case .chat: return "bubble.left"
        case .dashboard: return "square.grid.2x2"
        case .strategy: return "brain.head.profile"
        case .library: return "book"
        case .insights: return "chart.line.uptrend.xyaxis"
        }
    }

    var filledIcon: String {
        switch self {
        case .chat: return "bubble.left.fill"
        case .dashboard: return "square.grid.2x2.fill"
        case .strategy: return "brain.head.profile.fill"
        case .library: return "book.fill"
        case .insights: return "chart.line.uptrend.xyaxis"
        }
    }
}

struct EvlinTabBar: View {
    @Binding var selectedTab: EvlinTab

    var body: some View {
        HStack(spacing: 0) {
            ForEach(EvlinTab.allCases, id: \.self) { tab in
                tabItem(tab)
            }
        }
        .padding(.horizontal, Spacing.sm)
        .padding(.top, Spacing.sm)
        .padding(.bottom, -Spacing.md)
        .background(
            Color.evSurfaceContainerLowest
                .ignoresSafeArea(edges: .bottom)
        )
    }

    private func tabItem(_ tab: EvlinTab) -> some View {
        let isActive = selectedTab == tab

        return Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                selectedTab = tab
            }
        } label: {
            VStack(spacing: 5) {
                Image(systemName: isActive ? tab.filledIcon : tab.icon)
                    .font(.system(size: 18))
                    .frame(width: 24, height: 24)
                    .foregroundStyle(
                        isActive ? Color.evPrimary : Color.evOnSurface.opacity(0.4)
                    )

                Text(tab.rawValue)
                    .font(.system(size: 10, weight: .semibold))
                    .textCase(.uppercase)
                    .tracking(0.5)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .foregroundStyle(
                        isActive ? Color.evPrimary : Color.evOnSurface.opacity(0.4)
                    )
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(
                isActive
                    ? RoundedRectangle(cornerRadius: CornerRadius.lg)
                        .fill(Color.evSurfaceContainer)
                    : nil
            )
        }
        .buttonStyle(.plain)
    }
}
