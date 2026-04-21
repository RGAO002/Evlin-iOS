import SwiftUI

struct InsightsRecommendation: Identifiable, Hashable {
    let id = UUID()
    let iconSystemName: String
    let title: String
    let sub: String
}

struct InsightsAppStat: Identifiable, Hashable {
    let id = UUID()
    let name: String
    let time: String
    let pct: Double
    let color: Color
    let iconBg: Color
    let iconSystemName: String
}

struct InsightsCategoryStat: Identifiable, Hashable {
    let id = UUID()
    let label: String
    let time: String
    let color: Color
    let weight: Double
}

enum InsightsMockData {
    static let heroTitle = "Liam's late-night gaming is impacting morning focus."
    static let heroBody  = "Analysis shows a 45% increase in Roblox activity after 9:00 PM this week. This correlates with a slower start to educational tasks the following mornings."

    static let recommendations: [InsightsRecommendation] = [
        .init(iconSystemName: "timer",
              title: "15-min warning for TikTok",
              sub: "Help transition away smoothly"),
        .init(iconSystemName: "graduationcap",
              title: "Educational YouTube mode",
              sub: "Prioritize learning content"),
        .init(iconSystemName: "moon.stars",
              title: "8:30 PM Digital Sunset",
              sub: "Lock all non-essential apps"),
    ]

    static let dailyTotalHours: Int = 4
    static let dailyTotalMinutes: Int = 32
    static let deltaPct: Int = 12

    static let categories: [InsightsCategoryStat] = [
        .init(label: "Entertainment", time: "2h 15m", color: .evPrimary, weight: 135),
        .init(label: "Social", time: "1h 05m", color: .evSecondary, weight: 65),
        .init(label: "Games", time: "45m", color: .evTertiaryFixedDim, weight: 45),
    ]

    static let apps: [InsightsAppStat] = [
        .init(name: "YouTube", time: "1h 15m", pct: 0.68,
              color: Color(hex: 0xFF0000),
              iconBg: .white,
              iconSystemName: "play.rectangle.fill"),
        .init(name: "Roblox", time: "45m", pct: 0.40,
              color: Color(hex: 0xE2231A),
              iconBg: .black,
              iconSystemName: "gamecontroller.fill"),
        .init(name: "TikTok", time: "42m", pct: 0.38,
              color: Color(hex: 0xFF0050),
              iconBg: .black,
              iconSystemName: "music.note"),
    ]
}
