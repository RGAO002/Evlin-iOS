import SwiftUI

/// Mirrors `primitives.jsx :: EvProgressBar`.
/// Pill-clipped track + fill, animated width.
struct EvKidProgressBar: View {
    enum Tone { case primary, amber, red }
    let value: Double
    let max: Double
    let tone: Tone
    let height: CGFloat

    init(value: Double, max: Double = 100, tone: Tone = .primary, height: CGFloat = 14) {
        self.value = value
        self.max = max
        self.tone = tone
        self.height = height
    }

    private var pct: Double {
        Swift.max(0, Swift.min(1, value / max))
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(trackColor)
                Capsule().fill(fillColor)
                    .frame(width: geo.size.width * pct)
                    .animation(.easeOut(duration: 0.4), value: pct)
            }
        }
        .frame(height: height)
    }

    private var fillColor: Color {
        switch tone {
        case .primary, .amber: return EvlinKidColors.green500
        case .red:             return EvlinKidColors.green700
        }
    }
    private var trackColor: Color {
        switch tone {
        case .primary, .amber: return EvlinKidColors.green100
        case .red:             return EvlinKidColors.green200
        }
    }
}

#Preview {
    VStack(spacing: 12) {
        EvKidProgressBar(value: 70, max: 120, tone: .primary)
        EvKidProgressBar(value: 30, max: 120, tone: .amber)
        EvKidProgressBar(value: 10, max: 120, tone: .red)
    }
    .padding()
}
