import SwiftUI

/// Mirrors `primitives.jsx :: EvChip`.
/// Pill chip in 5 tones — all map into the green palette.
struct EvKidChip: View {
    enum Tone { case neutral, violet, green, amber, red }
    enum Size { case sm, md }

    let tone: Tone
    let size: Size
    let text: String

    init(_ text: String, tone: Tone = .neutral, size: Size = .sm) {
        self.text = text
        self.tone = tone
        self.size = size
    }

    var body: some View {
        Text(text)
            .font(.system(size: size == .sm ? 12 : 13, weight: .semibold))
            .tracking(0.1)
            .foregroundStyle(fg)
            .padding(.horizontal, size == .sm ? 10 : 12)
            .padding(.vertical, size == .sm ? 4 : 6)
            .background(bg, in: Capsule())
    }

    private var fg: Color {
        switch tone {
        case .neutral: return EvlinKidColors.ink2
        case .violet:  return EvlinKidColors.green700
        case .green:   return EvlinKidColors.green700
        case .amber:   return EvlinKidColors.green600
        case .red:     return EvlinKidColors.green800
        }
    }
    private var bg: Color {
        switch tone {
        case .neutral: return EvlinKidColors.surface2
        case .violet:  return EvlinKidColors.green100
        case .green:   return EvlinKidColors.green100
        case .amber:   return EvlinKidColors.green50
        case .red:     return EvlinKidColors.green200
        }
    }
}

#Preview {
    HStack {
        EvKidChip("Chores", tone: .violet)
        EvKidChip("Done", tone: .green)
        EvKidChip("Submitted", tone: .amber)
        EvKidChip("Overdue", tone: .red)
    }
    .padding()
}
