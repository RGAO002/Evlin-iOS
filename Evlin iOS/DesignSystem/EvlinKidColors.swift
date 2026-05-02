import SwiftUI

/// Kid-mode palette. Independent from `EvlinColors` (the parent navy palette).
/// Values mirror `Evlin_student_view/theme.jsx` const `EVLIN` exactly.
///
/// Status is encoded by **brightness** within a single green family — three tiers
/// of the same green = three tiers of urgency. Do not introduce new hues.
enum EvlinKidColors {
    // Green scale — 8 steps, light → dark
    static let green50  = Color(hex: 0xF0FAF3)
    static let green100 = Color(hex: 0xDDF3E3)
    static let green200 = Color(hex: 0xBEE6C9)
    static let green300 = Color(hex: 0x93D4A8)
    static let green400 = Color(hex: 0x5FBD7F)
    static let green500 = Color(hex: 0x2AA854)   // PRIMARY
    static let green600 = Color(hex: 0x1F8D43)
    static let green700 = Color(hex: 0x0F5E2B)
    static let green800 = Color(hex: 0x08401C)

    // Brand aliases
    static let primary     = green500
    static let primaryDark = green600
    static let primarySoft = green100
    static let primaryInk  = green700

    // Status aliases (legacy chip API tones — all map back into the green scale)
    static let amber     = green600
    static let amberSoft = green50
    static let red       = green700
    static let redSoft   = green100

    // Neutrals — green-tinted so white + greens read as one family
    static let ink     = Color(hex: 0x0E2417)
    static let ink2    = Color(hex: 0x44584D)
    static let ink3    = Color(hex: 0x7A8A81)
    static let ink4    = Color(hex: 0xC0CEC6)
    static let line    = Color(hex: 0xE4EEE8)
    static let surface  = Color.white
    static let surface2 = Color(hex: 0xF5FAF7)

    // Reflection-active palette (HomeReflection — brown/tan; theme.jsx does not export
    // these as tokens but home-reflection.jsx hardcodes them. Centralize here.)
    enum Reflection {
        static let bgSurface     = Color(hex: 0xF4E8D6)  // background
        static let cardBg        = Color(hex: 0xE4CBA1)  // hero card
        static let cardBorder    = Color(hex: 0xB7935E)  // hero card border
        static let cardAccent    = Color(hex: 0xD4B584)  // decorative dot
        static let iconBg        = Color(hex: 0xB7935E)  // lock icon container
        static let labelText     = Color(hex: 0x4A3215)  // "SCREEN TIME LOCKED"
        static let bodyText      = Color(hex: 0x6E4F26)  // body copy
        static let titleText     = Color(hex: 0x2E1F08)  // hero title
        static let buttonBg      = Color(hex: 0x2E1F08)  // primary CTA
        static let rowBorder     = Color(hex: 0xDDC59B)  // task row border
        static let rowBorderDone = Color(hex: 0xB7935E)
        static let rowBgSubmitted = Color(hex: 0xF4E8D6)
        static let rowBgDone     = Color(hex: 0xF4E8D6)
        static let chipBg        = Color(hex: 0xEAD7B4)
        static let chipFg        = Color(hex: 0x4A3215)
        static let pipDone       = Color(hex: 0x9A7340)
        static let pipSubmitted  = Color(hex: 0xB7935E)
        static let pipTodo       = Color(hex: 0xDDC59B)
        static let checkBg       = Color(hex: 0x9A7340)
    }
}

#Preview("Kid colors") {
    ScrollView {
        VStack(alignment: .leading, spacing: 8) {
            Group {
                swatch("green50",  EvlinKidColors.green50)
                swatch("green100", EvlinKidColors.green100)
                swatch("green200", EvlinKidColors.green200)
                swatch("green300", EvlinKidColors.green300)
                swatch("green400", EvlinKidColors.green400)
                swatch("green500 (primary)", EvlinKidColors.green500)
                swatch("green600", EvlinKidColors.green600)
                swatch("green700", EvlinKidColors.green700)
                swatch("green800", EvlinKidColors.green800)
            }
            Divider()
            Group {
                swatch("ink",      EvlinKidColors.ink)
                swatch("ink2",     EvlinKidColors.ink2)
                swatch("ink3",     EvlinKidColors.ink3)
                swatch("ink4",     EvlinKidColors.ink4)
                swatch("line",     EvlinKidColors.line)
                swatch("surface2", EvlinKidColors.surface2)
            }
            Divider()
            Group {
                swatch("Reflection.bgSurface",  EvlinKidColors.Reflection.bgSurface)
                swatch("Reflection.cardBg",     EvlinKidColors.Reflection.cardBg)
                swatch("Reflection.cardBorder", EvlinKidColors.Reflection.cardBorder)
                swatch("Reflection.buttonBg",   EvlinKidColors.Reflection.buttonBg)
            }
        }
        .padding()
    }
}

@ViewBuilder
private func swatch(_ name: String, _ color: Color) -> some View {
    HStack(spacing: 12) {
        RoundedRectangle(cornerRadius: 6)
            .fill(color)
            .frame(width: 48, height: 32)
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.black.opacity(0.1), lineWidth: 0.5)
            )
        Text(name).font(.system(size: 13, design: .monospaced))
        Spacer()
    }
}
