import SwiftUI

// MARK: - CTA button with variants
// Mirrors Esen's Button from ui.jsx lines 276-308.

enum EvlinButtonVariant { case primary, success, ghost, outline }
enum EvlinButtonSize { case sm, md, lg
    var fontSize: CGFloat { self == .sm ? 11 : self == .md ? 12 : 13 }
    var hPad: CGFloat { self == .sm ? 14 : self == .md ? 18 : 20 }
    var vPad: CGFloat { self == .sm ? 8 : self == .md ? 11 : 14 }
}

struct EvlinButton: View {
    let title: String
    var icon: String? = nil
    var variant: EvlinButtonVariant = .primary
    var size: EvlinButtonSize = .md
    var block: Bool = false
    var action: () -> Void = {}

    @State private var pressed = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 14, weight: .bold))
                }
                Text(title.uppercased())
                    .font(.custom("Manrope", size: size.fontSize).weight(.bold))
                    .tracking(0.9)
            }
            .foregroundStyle(fgColor)
            .padding(.horizontal, size.hPad)
            .padding(.vertical, size.vPad)
            .frame(maxWidth: block ? .infinity : nil)
            .background(bgShape)
            .shadow(color: shadowColor, radius: 12, x: 0, y: 4)
            .scaleEffect(pressed ? 0.98 : 1.0)
        }
        .buttonStyle(.plain)
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in pressed = true }
                .onEnded { _ in pressed = false }
        )
    }

    @ViewBuilder private var bgShape: some View {
        switch variant {
        case .primary:
            RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.evPrimaryGradient)
        case .success:
            RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.evSecondaryGradient)
        case .ghost:
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.clear)
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(Color.evOutlineVariant, lineWidth: 1)
                )
        case .outline:
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.white)
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(Color.evTertiaryFixed, lineWidth: 1)
                )
        }
    }

    private var fgColor: Color {
        switch variant {
        case .primary, .success: return .white
        case .ghost: return .evPrimary
        case .outline: return .evOnTertiaryContainer
        }
    }

    private var shadowColor: Color {
        switch variant {
        case .primary: return Color(hex: 0x041627).opacity(0.2)
        case .success: return Color(hex: 0x2E7D32).opacity(0.2)
        default: return .clear
        }
    }
}
