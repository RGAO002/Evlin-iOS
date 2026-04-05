import SwiftUI

// MARK: - Evlin Shadow Presets
// Source: "Ambient shadows using on-surface tint, not pure black"

extension View {
    /// Ambient shadow for floating cards
    func evAmbientShadow() -> some View {
        self.shadow(
            color: Color(hex: 0x191C1E).opacity(0.06),
            radius: 32,
            x: 0,
            y: 12
        )
    }

    /// Upward shadow for chat input bar
    func evChatInputShadow() -> some View {
        self.shadow(
            color: Color.black.opacity(0.05),
            radius: 40,
            x: 0,
            y: -10
        )
    }

    /// Top nav bar shadow
    func evNavBarShadow() -> some View {
        self.shadow(
            color: Color(hex: 0x191C1E).opacity(0.04),
            radius: 20,
            x: 0,
            y: -4
        )
    }

    /// Ghost border (outline-variant at 20% opacity)
    func evGhostBorder() -> some View {
        self.overlay(
            RoundedRectangle(cornerRadius: CornerRadius.lg)
                .stroke(Color.evOutlineVariant.opacity(0.2), lineWidth: 1)
        )
    }
}
