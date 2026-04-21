import SwiftUI

// MARK: - App Utilization Insights
// Pixel-matched to stitch_parent_dashboard/app_utilization_insights/screen.png
// All content is hardcoded for now.

struct InsightsView: View {
    @State private var selectedChildId: String = "liam"

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                childSelector
                    .padding(.top, 16)

                dailyUsageCard
                    .padding(.top, 16)

                detailedBreakdownHeader
                    .padding(.top, 32)

                VStack(spacing: 12) {
                    ForEach(InsightsMock.apps) { app in
                        AppUsageRow(app: app)
                    }
                }
                .padding(.top, 16)

                expertTipCard
                    .padding(.top, 32)
                    .padding(.bottom, 24)
            }
            .padding(.horizontal, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.evSurface)
    }

    // MARK: - Child selector pills

    private var childSelector: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                ChildPill(
                    label: "All",
                    icon: "person.2.fill",
                    isSelected: selectedChildId == "all"
                ) { selectedChildId = "all" }

                ForEach(ChildProfile.all) { child in
                    ChildPill(
                        label: child.name,
                        emoji: child.avatarEmoji,
                        isSelected: selectedChildId == child.id
                    ) { selectedChildId = child.id }
                }
            }
        }
    }

    // MARK: - Daily usage hero

    private var dailyUsageCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Top row: label + delta badge
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("DAILY APP USAGE")
                        .font(.custom("Manrope", size: 13).weight(.bold))
                        .tracking(2)
                        .foregroundStyle(Color.evOnSurfaceVariant)

                    Text("4h 32m")
                        .font(.custom("Manrope", size: 36).weight(.heavy))
                        .tracking(-1)
                        .foregroundStyle(Color.evPrimary)
                }

                Spacer()

                Text("+12% vs yesterday")
                    .font(.custom("Inter", size: 12).weight(.bold))
                    .foregroundStyle(Color.evSecondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.evSecondaryContainer.opacity(0.35))
                    )
            }
            .padding(.bottom, 24)

            // Category breakdown pills
            FlowLayout(spacing: 8) {
                CategoryPill(dot: Color.evPrimary,           name: "Entertainment", time: "2h 15m")
                CategoryPill(dot: Color.evSecondary,         name: "Social",        time: "1h 05m")
                CategoryPill(dot: Color.evTertiaryFixedDim,  name: "Games",         time: "45m")
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.evSurfaceContainerLowest)
        )
        .shadow(color: Color(hex: 0x191C1E).opacity(0.04), radius: 16, x: 0, y: 12)
    }

    // MARK: - Detailed breakdown header

    private var detailedBreakdownHeader: some View {
        HStack(alignment: .bottom) {
            Text("Detailed Breakdown")
                .font(.custom("Manrope", size: 20).weight(.bold))
                .foregroundStyle(Color.evPrimary)

            Spacer()

            Button {
                // no-op
            } label: {
                Text("VIEW ALL")
                    .font(.custom("Inter", size: 11).weight(.bold))
                    .tracking(0.5)
                    .foregroundStyle(Color.evPrimary)
                    .padding(.bottom, 2)
                    .overlay(
                        Rectangle()
                            .fill(Color.evPrimary)
                            .frame(height: 1.5),
                        alignment: .bottom
                    )
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Expert Tip card

    private var expertTipCard: some View {
        ZStack(alignment: .bottomTrailing) {
            // Decorative soft glow (matches design's blurred green orb)
            Circle()
                .fill(Color.evSecondary.opacity(0.15))
                .frame(width: 180, height: 180)
                .blur(radius: 60)
                .offset(x: 40, y: 40)

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "lightbulb.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(Color.evSecondaryFixed)
                    Text("EXPERT TIP")
                        .font(.custom("Inter", size: 11).weight(.bold))
                        .tracking(2)
                        .foregroundStyle(Color.evOnPrimaryContainer.opacity(0.8))
                }
                .padding(.bottom, 4)

                Text("Liam's evening usage is peaking.")
                    .font(.custom("Manrope", size: 18).weight(.bold))
                    .foregroundStyle(.white)
                    .fixedSize(horizontal: false, vertical: true)

                Text("Most screen time is occurring between 8 PM and 10 PM. Consider a \"Digital Sunset\" rule starting at 8:30 PM.")
                    .font(.custom("Inter", size: 14))
                    .foregroundStyle(Color.evOnPrimaryContainer)
                    .opacity(0.9)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 2)
            }
            .padding(24)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.evPrimaryContainer)
        )
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

// MARK: - Child Pill

private struct ChildPill: View {
    let label: String
    var icon: String? = nil
    var emoji: String? = nil
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 15))
                } else if let emoji {
                    Text(emoji).font(.system(size: 15))
                }

                Text(label)
                    .font(.custom("Inter", size: 14).weight(.semibold))
            }
            .foregroundStyle(isSelected ? .white : Color.evOnSurfaceVariant)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(
                Group {
                    if isSelected {
                        Capsule().fill(Color.evPrimary)
                    } else {
                        Capsule()
                            .fill(Color.evSurfaceContainerLow)
                            .overlay(
                                Capsule().stroke(Color.evOutlineVariant.opacity(0.2), lineWidth: 1)
                            )
                    }
                }
            )
            .shadow(
                color: isSelected ? Color.evPrimary.opacity(0.1) : .clear,
                radius: 8, x: 0, y: 2
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Category Pill

private struct CategoryPill: View {
    let dot: Color
    let name: String
    let time: String

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(dot)
                .frame(width: 8, height: 8)
            Text(name)
                .font(.custom("Inter", size: 12).weight(.semibold))
                .foregroundStyle(Color.evPrimary)
            Text(time)
                .font(.custom("Inter", size: 12))
                .foregroundStyle(Color.evOnSurfaceVariant)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.evSurfaceContainer)
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color.evOutlineVariant.opacity(0.1), lineWidth: 1)
                )
        )
    }
}

// MARK: - App Usage Row

private struct AppUsageRow: View {
    let app: InsightsMock.AppUsage

    var body: some View {
        HStack(spacing: 16) {
            // Icon tile
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(app.iconBg)
                    .frame(width: 48, height: 48)

                if let sys = app.systemImage {
                    Image(systemName: sys)
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(app.iconTint)
                } else {
                    Text(app.initial)
                        .font(.custom("Manrope", size: 22).weight(.heavy))
                        .foregroundStyle(app.iconTint)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(app.name)
                        .font(.custom("Manrope", size: 16).weight(.heavy))
                        .foregroundStyle(Color.evPrimary)
                    Spacer()
                    Text(app.time)
                        .font(.custom("Inter", size: 14).weight(.bold))
                        .tracking(-0.2)
                        .foregroundStyle(Color.evPrimary)
                }

                // Progress bar
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Color.evSurfaceContainerHighest)
                            .frame(height: 8)
                        Capsule()
                            .fill(Color.evPrimary)
                            .frame(width: geo.size.width * app.percent, height: 8)
                    }
                }
                .frame(height: 8)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.evSurfaceContainerLowest)
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(Color.evOutlineVariant.opacity(0.05), lineWidth: 1)
                )
        )
        .shadow(color: Color(hex: 0x191C1E).opacity(0.03), radius: 4, x: 0, y: 2)
    }
}

// MARK: - Mock data

private enum InsightsMock {
    struct AppUsage: Identifiable {
        let id = UUID()
        let name: String
        let time: String
        let percent: CGFloat
        let iconBg: Color
        let iconTint: Color
        let systemImage: String?
        let initial: String
    }

    static let apps: [AppUsage] = [
        AppUsage(
            name: "YouTube", time: "1h 15m", percent: 0.75,
            iconBg: Color(hex: 0xFF0000), iconTint: .white,
            systemImage: "play.fill", initial: "Y"
        ),
        AppUsage(
            name: "Roblox", time: "45m", percent: 0.45,
            iconBg: Color(hex: 0x232527), iconTint: .white,
            systemImage: nil, initial: "R"
        ),
        AppUsage(
            name: "TikTok", time: "42m", percent: 0.40,
            iconBg: .black, iconTint: .white,
            systemImage: "music.note", initial: "T"
        ),
        AppUsage(
            name: "Instagram", time: "28m", percent: 0.25,
            iconBg: Color(hex: 0xE1306C), iconTint: .white,
            systemImage: "camera.fill", initial: "I"
        ),
        AppUsage(
            name: "Discord", time: "22m", percent: 0.20,
            iconBg: Color(hex: 0x5865F2), iconTint: .white,
            systemImage: "gamecontroller.fill", initial: "D"
        )
    ]
}

// MARK: - Simple FlowLayout (wrapping HStack)

private struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0

        for sub in subviews {
            let size = sub.sizeThatFits(.unspecified)
            if x + size.width > maxWidth {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: maxWidth, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x: CGFloat = bounds.minX
        var y: CGFloat = bounds.minY
        var rowHeight: CGFloat = 0

        for sub in subviews {
            let size = sub.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            sub.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

// MARK: - Preview

#Preview {
    InsightsView()
}
