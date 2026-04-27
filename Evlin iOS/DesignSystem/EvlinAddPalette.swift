import SwiftUI

/// Visual constants used by AddBottomSheet, all forms, and TaskDetailSheet.
/// Centralized to keep all phases in sync.
enum EvlinAddPalette {
    /// HTML 483: BYPASS_PURPLE = '#7C3AED'
    static let bypass = Color(hex: 0x7C3AED)
    /// HTML 484: BYPASS_BG
    static let bypassBg = Color(hex: 0x7C3AED).opacity(0.08)

    /// Status banner (TaskDetailSheet HTML 740-750)
    static let reviewTone = Color(hex: 0xB26A00)
    static let reviewBg   = Color(hex: 0xFFA726).opacity(0.12)
    static let bypassTone = bypass
    static let bypassedBg = Color.evSurfaceContainerLow
    static let bypassedTone = Color.evOnSurfaceVariant
    static let overdueTone = Color.evError
    static let overdueBg = Color(hex: 0xF44336).opacity(0.10)
    static let doneTone = Color.evSecondary
    static let doneBg = Color(hex: 0x4CAF50).opacity(0.10)

    /// Form input (HTML 1194)
    static let formInputBorder = Color.evOutlineVariant
}
