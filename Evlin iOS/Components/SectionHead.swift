import SwiftUI

// MARK: - Section header row — title + optional kicker + right-side slot
// Mirrors Esen's SectionHead from ui.jsx lines 311-333.

struct SectionHead<Right: View>: View {
    let title: String
    var kicker: String? = nil
    @ViewBuilder var right: () -> Right

    var body: some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 4) {
                if let kicker {
                    Text(kicker.uppercased())
                        .font(.custom("Inter", size: 10).weight(.bold))
                        .tracking(1.6)
                        .foregroundStyle(Color.evOnSurfaceVariant)
                }
                Text(title)
                    .font(.custom("Manrope", size: 22).weight(.heavy))
                    .tracking(-0.33)
                    .foregroundStyle(Color.evPrimary)
                    .lineSpacing(-2)
            }
            Spacer()
            right()
        }
        .padding(.horizontal, 4)
        .padding(.bottom, 14)
    }
}

extension SectionHead where Right == EmptyView {
    init(_ title: String, kicker: String? = nil) {
        self.init(title: title, kicker: kicker, right: { EmptyView() })
    }
}
