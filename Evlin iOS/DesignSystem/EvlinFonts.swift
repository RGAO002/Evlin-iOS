import SwiftUI

// MARK: - Evlin Typography
// Manrope (headlines) + Inter (body) — "High-Low" editorial pairing
// Source: DESIGN.md — "The Informed Sentinel"

extension Font {
    // MARK: Display — Manrope

    /// 48pt — Significant data milestones
    static let evDisplayLarge = Font.custom("Manrope", size: 48).weight(.heavy)
    /// 40pt — Page editorial headers ("Deep Analysis")
    static let evHeadlineLarge = Font.custom("Manrope", size: 40).weight(.heavy)
    /// 24pt — Section headers
    static let evHeadlineMedium = Font.custom("Manrope", size: 24).weight(.bold)
    /// 20pt — Card titles, nav title
    static let evHeadlineSmall = Font.custom("Manrope", size: 20).weight(.bold)

    // MARK: Body — Inter

    /// 16pt — Main body text
    static let evBodyLarge = Font.custom("Inter", size: 16).weight(.regular)
    /// 14pt — Chat messages, descriptions
    static let evBodyMedium = Font.custom("Inter", size: 14).weight(.regular)
    /// 12pt — Secondary text, captions
    static let evBodySmall = Font.custom("Inter", size: 12).weight(.regular)

    // MARK: Labels — Inter

    /// 14pt semibold — Button labels, emphasis
    static let evLabelLarge = Font.custom("Inter", size: 14).weight(.semibold)
    /// 11pt bold — Section labels ("STRATEGIC CONTEXT")
    static let evLabelMedium = Font.custom("Inter", size: 11).weight(.bold)
    /// 10pt bold — Timestamps ("SENT 8:12 PM")
    static let evLabelSmall = Font.custom("Inter", size: 10).weight(.bold)
    /// 11pt semibold — Tags, chips
    static let evCaption = Font.custom("Inter", size: 11).weight(.semibold)
}

// MARK: - View modifiers for common text styles

extension View {
    /// Uppercase, wide tracking label style
    func evLabelStyle() -> some View {
        self.textCase(.uppercase)
            .tracking(1.5)
    }

    /// Wider tracking for timestamps
    func evTimestampStyle() -> some View {
        self.font(.evLabelSmall)
            .foregroundStyle(Color.evOutline)
            .textCase(.uppercase)
            .tracking(2.0)
    }
}
