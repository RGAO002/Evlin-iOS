import SwiftUI

// MARK: - Premium surface card
// Mirrors Esen's Card from ui.jsx lines 157-178.

struct EvlinCard<Content: View>: View {
    var padded: Bool = true
    var hover: Bool = false
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .padding(padded ? 20 : 0)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(Color.evSurfaceContainerLowest)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(Color.evOutlineVariant.opacity(0.4), lineWidth: 1)
            )
            .evShadow(.premium)
    }
}
