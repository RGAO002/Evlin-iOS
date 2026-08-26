import SwiftUI

enum EvlinV2ProfileTokens {
    static let primary = Color(red: 0.082, green: 0.137, blue: 0.102)
    static let accent = Color(red: 0.153, green: 0.573, blue: 0.290)
    static let danger = Color(red: 0.768, green: 0.153, blue: 0.173)
    static let surface = Color.white
    static let surfaceMuted = Color(red: 0.957, green: 0.969, blue: 0.957)
    static let textMuted = Color(red: 0.330, green: 0.384, blue: 0.345)
    static let outline = Color(red: 0.835, green: 0.859, blue: 0.839)

    static func font(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        let family: String
        switch weight {
        case .heavy, .black:
            family = "PlusJakartaSans-ExtraBold"
        case .bold:
            family = "PlusJakartaSans-Bold"
        case .semibold:
            family = "PlusJakartaSans-SemiBold"
        case .medium:
            family = "PlusJakartaSans-Medium"
        default:
            family = "PlusJakartaSans-Regular"
        }
        return .custom(family, size: size, relativeTo: .body)
    }
}
