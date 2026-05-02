import SwiftUI

/// Mirrors `primitives.jsx :: EvBigButton`.
/// 58pt tall, 18pt radius, 17pt SemiBold, soft shadow tinted with the button bg.
struct EvKidBigButton<Label: View>: View {
    enum Tone { case primary, ghost }
    let tone: Tone
    let isDisabled: Bool
    let action: () -> Void
    @ViewBuilder let label: () -> Label

    init(tone: Tone = .primary,
         isDisabled: Bool = false,
         action: @escaping () -> Void,
         @ViewBuilder label: @escaping () -> Label) {
        self.tone = tone
        self.isDisabled = isDisabled
        self.action = action
        self.label = label
    }

    var body: some View {
        Button(action: { if !isDisabled { action() } }) {
            label()
                .font(.system(size: 17, weight: .semibold))
                .tracking(EvlinKidMetrics.Letter.body)
                .frame(maxWidth: .infinity)
                .frame(height: EvlinKidMetrics.Size.buttonHeight)
                .foregroundStyle(foreground)
                .background(background)
                .clipShape(RoundedRectangle(cornerRadius: EvlinKidMetrics.Radius.button))
                .overlay(borderOverlay)
                .shadow(color: shadowColor, radius: 8, x: 0, y: 6)
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
    }

    private var foreground: Color {
        if isDisabled { return .white }
        switch tone {
        case .primary: return .white
        case .ghost:   return EvlinKidColors.ink
        }
    }
    private var background: Color {
        if isDisabled { return EvlinKidColors.ink4 }
        switch tone {
        case .primary: return EvlinKidColors.green500
        case .ghost:   return EvlinKidColors.surface
        }
    }
    @ViewBuilder
    private var borderOverlay: some View {
        if tone == .ghost {
            RoundedRectangle(cornerRadius: EvlinKidMetrics.Radius.button)
                .stroke(EvlinKidColors.line, lineWidth: 1.5)
        } else {
            EmptyView()
        }
    }
    private var shadowColor: Color {
        if isDisabled || tone == .ghost { return .clear }
        return EvlinKidColors.green500.opacity(0.25)
    }
}

#Preview {
    VStack(spacing: 16) {
        EvKidBigButton(action: {}) { Text("Continue") }
        EvKidBigButton(tone: .ghost, action: {}) { Text("Back to today") }
        EvKidBigButton(isDisabled: true, action: {}) { Text("Disabled") }
    }
    .padding()
}
