import SwiftUI

// MARK: - Flat 5-tab bar (post-Esen-refresh)
// All tabs equal weight; selection indicator = short capsule at top of tab.

enum EvlinTab: String, CaseIterable, Hashable {
    case home = "Home"
    case calendar = "Calendar"
    case chat = "Chat"
    case library = "Library"
    case insights = "Insights"

    var sfSymbol: String {
        switch self {
        case .home: return "house"
        case .calendar: return "calendar"
        case .chat: return "bubble.left"
        case .library: return "books.vertical"
        case .insights: return "chart.bar"
        }
    }

    var sfSymbolFilled: String {
        switch self {
        case .home: return "house.fill"
        case .calendar: return "calendar"
        case .chat: return "bubble.left.fill"
        case .library: return "books.vertical.fill"
        case .insights: return "chart.bar.fill"
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
        .padding(.horizontal, 4)
        .frame(height: 76)
        .background(
            Color.evSurfaceContainerLowest.opacity(0.92)
                .background(.ultraThinMaterial)
                .ignoresSafeArea(edges: .bottom)
        )
        .overlay(
            Rectangle()
                .fill(Color.evOutlineVariant)
                .frame(height: 0.5),
            alignment: .top
        )
    }

    private func tabItem(_ tab: EvlinTab) -> some View {
        let isActive = selectedTab == tab
        return Button {
            withAnimation(.easeInOut(duration: 0.18)) {
                selectedTab = tab
            }
        } label: {
            VStack(spacing: 6) {
                TabBarIndicator()
                    .fill(isActive ? Color.evPrimary : Color.clear)
                    .frame(width: 34, height: 5)

                Image(systemName: isActive ? tab.sfSymbolFilled : tab.sfSymbol)
                    .font(.system(size: 22, weight: isActive ? .semibold : .regular))
                    .frame(height: 26)
                    .foregroundStyle(isActive ? Color.evPrimary : Color.evOnSurfaceVariant)

                Text(tab.rawValue.uppercased())
                    .font(.custom("Manrope", size: 10).weight(.heavy))
                    .tracking(0.4)
                    .foregroundStyle(isActive ? Color.evPrimary : Color.evOnSurfaceVariant)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 0)   // indicator hugs the tab bar's top edge
            .padding(.bottom, 10)
            .opacity(isActive ? 1.0 : 0.55)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Trapezoid selection indicator (top wider than bottom, flat top)

private struct TabBarIndicator: Shape {
    func path(in rect: CGRect) -> Path {
        // Top edge flush with tab bar top; sides taper inward to a narrower rounded bottom.
        let inset: CGFloat = rect.height * 0.9
        let r: CGFloat = min(1.5, rect.height * 0.4)

        var p = Path()
        // Top-left
        p.move(to: CGPoint(x: 0, y: 0))
        // Top-right (flat top edge)
        p.addLine(to: CGPoint(x: rect.width, y: 0))
        // Taper down to bottom-right
        p.addLine(to: CGPoint(x: rect.width - inset + r, y: rect.height - r))
        // Small rounded corner at bottom-right
        p.addQuadCurve(
            to: CGPoint(x: rect.width - inset, y: rect.height),
            control: CGPoint(x: rect.width - inset, y: rect.height - r)
        )
        // Bottom edge
        p.addLine(to: CGPoint(x: inset, y: rect.height))
        // Small rounded corner at bottom-left
        p.addQuadCurve(
            to: CGPoint(x: inset - r, y: rect.height - r),
            control: CGPoint(x: inset, y: rect.height - r)
        )
        // Taper back up to top-left
        p.addLine(to: CGPoint(x: 0, y: 0))
        p.closeSubpath()
        return p
    }
}

#Preview {
    @Previewable @State var tab: EvlinTab = .home
    return VStack { Spacer(); EvlinTabBar(selectedTab: $tab) }
        .background(Color.evSurface)
}
