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
    static let barHeight: CGFloat = 72
    static let bottomOffset: CGFloat = -20 
    static let visibleHeight: CGFloat = barHeight + bottomOffset
    static let indicatorTopInset: CGFloat = 0

    @Binding var selectedTab: EvlinTab

    var body: some View {
        HStack(spacing: 0) {
            ForEach(EvlinTab.allCases, id: \.self) { tab in
                tabItem(tab)
            }
        }
        .padding(.horizontal, 4)
        .frame(height: Self.barHeight)
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
                    .frame(width: 30, height: 3.5)

                Image(systemName: isActive ? tab.sfSymbolFilled : tab.sfSymbol)
                    .font(.system(size: 22, weight: isActive ? .semibold : .regular))
                    .frame(height: 26)
                    .foregroundStyle(isActive ? Color.evPrimary : Color.evOnSurfaceVariant)

                Text(tab.rawValue.uppercased())
                    .font(.custom("Manrope", size: 10).weight(.heavy))
                    .tracking(0.4)
                    .foregroundStyle(isActive ? Color.evPrimary : Color.evOnSurfaceVariant)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(.top, Self.indicatorTopInset)
            .padding(.bottom, 6)
            .opacity(isActive ? 1.0 : 0.55)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Trapezoid selection indicator (top wider than bottom, flat top)

private struct TabBarIndicator: Shape {
    func path(in rect: CGRect) -> Path {
        // A mostly-horizontal bar with a gentle inward taper at the bottom
        // and small rounding on all four corners.
        let w = rect.width
        let h = rect.height
        let inset: CGFloat = 2.5   // bottom taper from each side
        let r: CGFloat = 1         // corner rounding

        var p = Path()
        // Top edge (starts after top-left corner)
        p.move(to: CGPoint(x: r, y: 0))
        p.addLine(to: CGPoint(x: w - r, y: 0))
        // Top-right corner
        p.addQuadCurve(to: CGPoint(x: w, y: r), control: CGPoint(x: w, y: 0))
        // Right side tapering inward
        p.addLine(to: CGPoint(x: w - inset + r, y: h - r))
        // Bottom-right corner
        p.addQuadCurve(to: CGPoint(x: w - inset, y: h), control: CGPoint(x: w - inset, y: h - r))
        // Bottom edge
        p.addLine(to: CGPoint(x: inset, y: h))
        // Bottom-left corner
        p.addQuadCurve(to: CGPoint(x: inset - r, y: h - r), control: CGPoint(x: inset, y: h - r))
        // Left side tapering back out
        p.addLine(to: CGPoint(x: 0, y: r))
        // Top-left corner
        p.addQuadCurve(to: CGPoint(x: r, y: 0), control: CGPoint(x: 0, y: 0))
        p.closeSubpath()
        return p
    }
}

#Preview {
    @Previewable @State var tab: EvlinTab = .home
    return VStack { Spacer(); EvlinTabBar(selectedTab: $tab) }
        .background(Color.evSurface)
}
