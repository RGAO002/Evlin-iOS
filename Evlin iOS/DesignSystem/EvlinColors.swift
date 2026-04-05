import SwiftUI

// MARK: - Evlin Design Tokens: "The Informed Sentinel"
// Source: stitch_parent_dashboard/evlin_ethos/DESIGN.md

extension Color {
    // MARK: Primary
    static let evPrimary = Color(hex: 0x041627)            // Deep navy — primary actions, headings, parent bubbles
    static let evPrimaryContainer = Color(hex: 0x1A2B3C)   // Gradient end, secondary navy
    static let evOnPrimary = Color.white
    static let evOnPrimaryContainer = Color(hex: 0x8192A7) // Subtitle text in headers
    static let evPrimaryFixed = Color(hex: 0xD2E4FB)       // Hover states, underlines
    static let evPrimaryFixedDim = Color(hex: 0xB7C8DE)    // Thinking indicator

    // MARK: Secondary (positive / safe)
    static let evSecondary = Color(hex: 0x1B6D24)           // Green — active states, success
    static let evSecondaryContainer = Color(hex: 0xA0F399)  // Active toggle tracks
    static let evSecondaryFixed = Color(hex: 0xA3F69C)      // Bright green accent
    static let evSecondaryFixedDim = Color(hex: 0x88D982)   // Numbered list markers

    // MARK: Tertiary (consequences / rules)
    static let evTertiary = Color(hex: 0x261000)            // Deep brown
    static let evTertiaryContainer = Color(hex: 0xDA7807)   // Recommendation icon
    static let evTertiaryFixed = Color(hex: 0xFFDCC3)       // Warm amber bg
    static let evTertiaryFixedDim = Color(hex: 0xFFB77D)    // Caution amber

    // MARK: Surface (backgrounds)
    static let evSurface = Color(hex: 0xF9F9FD)                // App background
    static let evSurfaceContainerLowest = Color.white           // Floating cards
    static let evSurfaceContainerLow = Color(hex: 0xF3F3F7)    // Section backgrounds
    static let evSurfaceContainer = Color(hex: 0xEDEEF1)       // Sidebar, active nav bg
    static let evSurfaceContainerHigh = Color(hex: 0xE7E8EB)   // User messages alt
    static let evSurfaceContainerHighest = Color(hex: 0xE2E2E6) // Input fields
    static let evSurfaceDim = Color(hex: 0xD9DADD)             // Inactive nav

    // MARK: On-Surface (text)
    static let evOnSurface = Color(hex: 0x191C1E)              // Primary body text
    static let evOnSurfaceVariant = Color(hex: 0x44474C)       // Secondary body text
    static let evOutline = Color(hex: 0x74777D)                // Timestamps, placeholders
    static let evOutlineVariant = Color(hex: 0xC4C6CD)         // Ghost borders (use at 20%)

    // MARK: Error
    static let evError = Color(hex: 0xBA1A1A)

    // MARK: Gradients
    static let evChatGradient = LinearGradient(
        colors: [Color(hex: 0x041627), Color(hex: 0x1A2B3C)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
}

// MARK: - Hex Initializer

extension Color {
    init(hex: UInt, alpha: Double = 1.0) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: alpha
        )
    }
}
