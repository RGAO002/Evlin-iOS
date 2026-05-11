import SwiftUI

/// Mirrors `primitives.jsx :: EvCard`. 6 tones, 20pt radius, 1px border.
struct EvKidCard<Content: View>: View {
    /// `bypassNotice` — parent declined a skip/bypass request (purple frame, matches parent bypass accent).
    enum Tone { case plain, amber, green, red, violet, tinted, bypassNotice }
    let tone: Tone
    let padding: CGFloat
    @ViewBuilder let content: () -> Content

    init(tone: Tone = .plain,
         padding: CGFloat = 20,
         @ViewBuilder content: @escaping () -> Content) {
        self.tone = tone
        self.padding = padding
        self.content = content
    }

    var body: some View {
        content()
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(bg)
            .clipShape(RoundedRectangle(cornerRadius: EvlinKidMetrics.Radius.card))
            .overlay(
                RoundedRectangle(cornerRadius: EvlinKidMetrics.Radius.card)
                    .stroke(border, lineWidth: 1)
            )
    }

    private var bg: Color {
        switch tone {
        case .plain:  return EvlinKidColors.surface
        case .amber:  return EvlinKidColors.green50
        case .green:  return EvlinKidColors.green100
        case .red:    return EvlinKidColors.green200
        case .violet: return EvlinKidColors.green50
        case .tinted: return EvlinKidColors.surface2
        case .bypassNotice: return EvlinAddPalette.bypassBg
        }
    }
    private var border: Color {
        switch tone {
        case .plain, .tinted: return EvlinKidColors.line
        case .amber, .violet: return EvlinKidColors.green200
        case .green:          return EvlinKidColors.green200
        case .red:            return EvlinKidColors.green300
        case .bypassNotice:   return EvlinAddPalette.bypass.opacity(0.42)
        }
    }
}

#Preview {
    VStack(spacing: 16) {
        EvKidCard { Text("Plain card") }
        EvKidCard(tone: .green) { Text("Green card") }
        EvKidCard(tone: .amber) { Text("Amber card") }
        EvKidCard(tone: .tinted) { Text("Tinted card") }
    }
    .padding()
}
