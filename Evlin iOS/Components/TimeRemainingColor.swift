import SwiftUI

extension Color {
    /// Three-tier fill color for a REMAINING-time bar (device daily cap, total
    /// time pool, home child card). `remainingFraction` is remaining/total
    /// (1.0 = full, 0 = empty):
    ///   • > ⅔ remaining  → green  (the app's existing "full" color, `evSecondary`)
    ///   • ⅓ … ⅔ remaining → amber/yellow (a third or more has been used)
    ///   • ≤ ⅓ remaining   → red    (`evError`, almost out)
    ///
    /// Threshold logic lives in `EarnedDisplayFormatters.remainingTier` (pure,
    /// unit-tested); this only maps the tier to a concrete color so every
    /// countdown bar stays consistent.
    static func evTimeRemaining(_ remainingFraction: Double) -> Color {
        switch EarnedDisplayFormatters.remainingTier(fraction: remainingFraction) {
        case .green:  return .evSecondary
        case .yellow: return Color(hex: 0xF59E0B)   // amber-500 (yellow warning)
        case .red:    return .evError
        }
    }
}
