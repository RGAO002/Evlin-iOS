import SwiftUI

struct InsightsView: View {
    @State private var selection: String = "liam"
    @State private var heroDismissed: Bool = false
    @State private var toastText: String? = nil

    var body: some View {
        VStack(spacing: 0) {
            GlassmorphicHeader(title: "Child Insights", kicker: "Past 7 days") {
                HStack(spacing: 4) {
                    HeaderIconButton(systemName: "bell", badge: true) {}
                    HeaderIconButton(systemName: "gearshape") {}
                }
            }

            ScrollView {
                VStack(spacing: 22) {
                    ChildFilterPills(selection: $selection)
                        .padding(.horizontal, -4)

                    if !heroDismissed {
                        heroCard
                    }

                    recommendations

                    dailyUsageCard

                    detailedBreakdown
                }
                .padding(20)
                .padding(.bottom, 40)
            }
        }
        .background(Color.evSurfaceContainerLow)
        .overlay(alignment: .bottom) {
            if let text = toastText {
                Text(text)
                    .font(.custom("Inter", size: 13).weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(Capsule().fill(Color.black.opacity(0.78)))
                    .padding(.bottom, 90)
                    .transition(.opacity)
                    .onAppear {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2.4) {
                            withAnimation { toastText = nil }
                        }
                    }
            }
        }
        .animation(.easeInOut(duration: 0.2), value: toastText)
    }

    private var heroCard: some View {
        ZStack(alignment: .bottomTrailing) {
            Circle().fill(Color.evSecondary.opacity(0.15))
                .frame(width: 180, height: 180)
                .blur(radius: 60)
                .offset(x: 40, y: 40)

            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(Color.evSecondaryGradient)
                            .frame(width: 26, height: 26)
                        Image(systemName: "sparkles")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(.white)
                    }
                    Text("EVLIN AI ANALYSIS")
                        .font(.custom("Inter", size: 10).weight(.heavy))
                        .tracking(1.6)
                        .foregroundStyle(Color.evSecondaryFixed)
                }
                .padding(.bottom, 4)

                Text(InsightsMockData.heroTitle)
                    .font(.custom("Manrope", size: 22).weight(.heavy))
                    .tracking(-0.25)
                    .foregroundStyle(.white)
                    .lineSpacing(-2)
                    .fixedSize(horizontal: false, vertical: true)

                Text(InsightsMockData.heroBody)
                    .font(.custom("Inter", size: 13))
                    .foregroundStyle(.white.opacity(0.7))
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 10) {
                    EvlinButton(title: "Review strategy", icon: "checkmark.seal", variant: .success, size: .sm) {
                        toastText = "Strategy details coming soon."
                    }
                    Button {
                        withAnimation(.easeOut(duration: 0.25)) { heroDismissed = true }
                    } label: {
                        Text("DISMISS")
                            .font(.custom("Manrope", size: 11).weight(.heavy))
                            .tracking(0.9)
                            .foregroundStyle(.white.opacity(0.9))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .overlay(
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .stroke(.white.opacity(0.2), lineWidth: 1)
                            )
                    }
                    .buttonStyle(.plain)
                }
                .padding(.top, 6)
            }
            .padding(22)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color.evPrimaryGradient)
        )
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private var recommendations: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHead(title: "Strategic Recommendations", kicker: "3 suggested") {
                EmptyView()
            }
            VStack(spacing: 0) {
                ForEach(Array(InsightsMockData.recommendations.enumerated()), id: \.element.id) { idx, r in
                    HStack(spacing: 14) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(Color.evSurfaceContainerLow)
                            Image(systemName: r.iconSystemName)
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundStyle(Color.evPrimary)
                        }
                        .frame(width: 40, height: 40)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(r.title)
                                .font(.custom("Manrope", size: 14).weight(.bold))
                                .foregroundStyle(Color.evOnSurface)
                            Text(r.sub)
                                .font(.custom("Inter", size: 11))
                                .foregroundStyle(Color.evOnSurfaceVariant)
                        }
                        Spacer()
                        EvlinButton(title: "Apply", size: .sm) {
                            toastText = "Recommendation applied."
                        }
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 14)
                    .overlay(
                        Rectangle()
                            .fill(Color.evOutlineVariant.opacity(idx == 0 ? 0 : 0.25))
                            .frame(height: 1),
                        alignment: .top
                    )
                }
            }
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color.evSurfaceContainerLowest)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Color.evOutlineVariant.opacity(0.4), lineWidth: 1)
            )
            .evShadow(.premium)
        }
    }

    private var dailyUsageCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHead(title: "Daily App Usage") {
                EvlinPill(text: "+\(InsightsMockData.deltaPct)% vs yesterday", tone: .success, size: .xs)
            }

            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("\(InsightsMockData.dailyTotalHours)h")
                        .font(.custom("Manrope", size: 48).weight(.heavy))
                        .tracking(-1.0)
                        .foregroundStyle(Color.evPrimary)
                    Text(String(format: "%02dm", InsightsMockData.dailyTotalMinutes))
                        .font(.custom("Manrope", size: 32).weight(.heavy))
                        .tracking(-0.6)
                        .foregroundStyle(Color.evPrimary)
                }

                GeometryReader { geo in
                    let total = InsightsMockData.categories.map(\.weight).reduce(0, +)
                    HStack(spacing: 0) {
                        ForEach(InsightsMockData.categories) { c in
                            Rectangle().fill(c.color)
                                .frame(width: geo.size.width * c.weight / total)
                        }
                    }
                    .frame(height: 6)
                    .clipShape(Capsule())
                }
                .frame(height: 6)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 18) {
                        ForEach(InsightsMockData.categories) { c in
                            HStack(spacing: 6) {
                                Circle().fill(c.color).frame(width: 8, height: 8)
                                Text(c.label)
                                    .font(.custom("Inter", size: 11).weight(.semibold))
                                    .foregroundStyle(Color.evOnSurface)
                                Text(c.time)
                                    .font(.custom("Inter", size: 11))
                                    .foregroundStyle(Color.evOnSurfaceVariant)
                            }
                            .fixedSize(horizontal: true, vertical: false)
                        }
                    }
                }
            }
            .padding(20)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color.evSurfaceContainerLowest)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Color.evOutlineVariant.opacity(0.4), lineWidth: 1)
            )
            .evShadow(.premium)
        }
    }

    private var detailedBreakdown: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHead(title: "Detailed Breakdown") {
                Text("VIEW ALL")
                    .font(.custom("Inter", size: 10).weight(.heavy))
                    .tracking(1.4)
                    .foregroundStyle(Color.evPrimary)
            }

            VStack(spacing: 10) {
                ForEach(InsightsMockData.apps) { app in
                    HStack(spacing: 14) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 11, style: .continuous)
                                .fill(app.iconBg)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                                        .stroke(Color.black.opacity(0.06), lineWidth: 1)
                                )
                            Image(systemName: app.iconSystemName)
                                .font(.system(size: 18, weight: .bold))
                                .foregroundStyle(app.color)
                        }
                        .frame(width: 38, height: 38)

                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(app.name)
                                    .font(.custom("Manrope", size: 14).weight(.heavy))
                                    .foregroundStyle(Color.evOnSurface)
                                Spacer()
                                Text(app.time)
                                    .font(.custom("Inter", size: 12).weight(.semibold))
                                    .foregroundStyle(Color.evOnSurfaceVariant)
                            }
                            GeometryReader { geo in
                                ZStack(alignment: .leading) {
                                    Capsule().fill(Color.evSurfaceContainerHigh)
                                    Capsule().fill(app.color)
                                        .frame(width: max(6, geo.size.width * app.pct))
                                }
                            }
                            .frame(height: 4)
                        }
                    }
                    .padding(14)
                    .background(
                        RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.evSurfaceContainerLowest)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Color.evOutlineVariant.opacity(0.35), lineWidth: 1)
                    )
                }
            }
        }
    }
}

#Preview {
    InsightsView()
}
