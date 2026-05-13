import SwiftUI

// MARK: - Evlin Design Tokens: "The Informed Sentinel"
// Aligned with frontend_for_app_evlin/tokens.js (Apr 2026 refresh)

extension Color {
    // MARK: Primary
    static let evPrimary = Color(hex: 0x041627)
    static let evPrimaryContainer = Color(hex: 0xF0F4F8)   // lightened — was navy container
    static let evOnPrimary = Color.white
    static let evOnPrimaryContainer = Color(hex: 0x8192A7)
    static let evPrimaryFixed = Color(hex: 0xD2E4FB)
    static let evPrimaryFixedDim = Color(hex: 0xB7C8DE)

    // MARK: Secondary (success / unlocked)
    static let evSecondary = Color(hex: 0x2E7D32)           // lighter forest
    static let evSecondaryContainer = Color(hex: 0xE8F5E9)  // pale container
    static let evSecondaryFixed = Color(hex: 0xC8E6C9)
    static let evSecondaryFixedDim = Color(hex: 0x88D982)
    static let evOnSecondaryContainer = Color(hex: 0x2E7D32)

    // MARK: Tertiary (caution / amber)
    static let evTertiary = Color(hex: 0x261000)
    static let evTertiaryContainer = Color(hex: 0xFFF3E0)
    static let evTertiaryFixed = Color(hex: 0xFFDCC3)
    static let evTertiaryFixedDim = Color(hex: 0xFFB77D)
    static let evOnTertiaryContainer = Color(hex: 0xE65100)

    // MARK: Surface
    static let evSurface = Color(hex: 0xFCFCFD)                 // was F9F9FD
    static let evSurfaceContainerLowest = Color.white
    static let evSurfaceContainerLow = Color(hex: 0xF7F8FA)
    static let evSurfaceContainer = Color(hex: 0xF1F2F4)
    static let evSurfaceContainerHigh = Color(hex: 0xEEF0F3)
    static let evSurfaceContainerHighest = Color(hex: 0xE2E2E6)
    static let evSurfaceDim = Color(hex: 0xD9DADD)

    // MARK: Reflection
    static let evReflectionSurface = Color(hex: 0xF4E7CF)
    static let evReflectionBorder = Color(hex: 0xC99B55)
    static let evReflectionBadge = Color(hex: 0xDCCDB4)
    static let evOnReflectionBadge = Color(hex: 0x5B4023)

    // MARK: On-Surface
    static let evOnSurface = Color(hex: 0x1A1C1E)
    static let evOnSurfaceVariant = Color(hex: 0x5A5E66)        // was 44474C
    static let evOutline = Color(hex: 0x8E9199)
    static let evOutlineVariant = Color(hex: 0xE2E4E9)          // was C4C6CD

    // MARK: Error
    static let evError = Color(hex: 0xD32F2F)
    static let evErrorContainer = Color(hex: 0xFFEBEE)

    // MARK: Per-child accents (NEW)
    static let evChildLiam = Color(hex: 0x2563EB)   // calm blue
    static let evChildMaya = Color(hex: 0x2E7D32)   // forest (same as evSecondary)
    static let evChildEmma = Color(hex: 0xEF6C00)   // amber

    // MARK: Gradients
    static let evChatGradient = LinearGradient(
        colors: [Color(hex: 0x041627), Color(hex: 0x1A2B3C)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
    static let evPrimaryGradient = LinearGradient(
        colors: [Color(hex: 0x041627), Color(hex: 0x1A2B3C)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
    static let evSecondaryGradient = LinearGradient(
        colors: [Color(hex: 0x2E7D32), Color(hex: 0x4CAF50)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
    static let evTertiaryGradient = LinearGradient(
        colors: [Color(hex: 0xEF6C00), Color(hex: 0xFF9800)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
}

// MARK: - Premium shadow helpers
enum EvlinShadowToken {
    case premium, premiumHover, ambient
    var color: Color {
        switch self {
        case .premium, .premiumHover: return .black
        case .ambient: return Color(hex: 0x191C1E)
        }
    }
    var opacity: Double {
        switch self {
        case .premium: return 0.04
        case .premiumHover: return 0.08
        case .ambient: return 0.06
        }
    }
    var radius: CGFloat {
        switch self {
        case .premium: return 30
        case .premiumHover: return 40
        case .ambient: return 32
        }
    }
    var y: CGFloat {
        switch self {
        case .premium: return 10
        case .premiumHover: return 20
        case .ambient: return 12
        }
    }
}

extension View {
    func evShadow(_ token: EvlinShadowToken) -> some View {
        self.shadow(color: token.color.opacity(token.opacity), radius: token.radius, x: 0, y: token.y)
    }
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
