import SwiftUI

// MARK: - Evlin status chip / pill
// Mirrors Esen's Pill from ui.jsx lines 203-233.

enum EvlinPillTone {
    case neutral, success, warn, danger, primary, liam, maya, emma

    var bg: Color {
        switch self {
        case .neutral: return .evSurfaceContainerHigh
        case .success: return .evSecondaryContainer
        case .warn:    return .evTertiaryFixed
        case .danger:  return .evErrorContainer
        case .primary: return .evPrimaryContainer
        case .liam:    return Color(hex: 0x2563EB).opacity(0.10)
        case .maya:    return Color(hex: 0x2E7D32).opacity(0.10)
        case .emma:    return Color(hex: 0xEF6C00).opacity(0.10)
        }
    }
    var fg: Color {
        switch self {
        case .neutral: return .evOnSurfaceVariant
        case .success: return .evSecondary
        case .warn:    return .evOnTertiaryContainer
        case .danger:  return .evError
        case .primary: return .evPrimary
        case .liam:    return .evChildLiam
        case .maya:    return .evChildMaya
        case .emma:    return .evChildEmma
        }
    }
}

enum EvlinPillSize { case xs, sm, md
    var fontSize: CGFloat { self == .xs ? 9 : self == .sm ? 10 : 11 }
    var hPad: CGFloat { self == .xs ? 8 : self == .sm ? 10 : 12 }
    var vPad: CGFloat { self == .xs ? 3 : self == .sm ? 5 : 6 }
}

struct EvlinPill: View {
    let text: String
    var tone: EvlinPillTone = .neutral
    var size: EvlinPillSize = .sm
    var outlined: Bool = false

    var body: some View {
        Text(text.uppercased())
            .font(.custom("Inter", size: size.fontSize).weight(.heavy))
            .tracking(1.3)
            .foregroundStyle(tone.fg)
            .padding(.horizontal, size.hPad)
            .padding(.vertical, size.vPad)
            .background(
                Capsule()
                    .fill(outlined ? Color.clear : tone.bg)
                    .overlay(
                        Capsule().stroke(outlined ? tone.fg.opacity(0.25) : Color.clear, lineWidth: 1)
                    )
            )
    }
}
