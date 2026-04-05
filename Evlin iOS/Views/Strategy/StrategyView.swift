import SwiftUI

struct StrategyView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xl) {
            Text("Strategy")
                .font(.evHeadlineLarge)
                .foregroundStyle(Color.evPrimary)
            Text("Behavioral strategies & recommendations")
                .font(.evBodyMedium)
                .foregroundStyle(Color.evOnSurfaceVariant)
            Spacer()
            HStack {
                Spacer()
                Text("Coming Soon")
                    .font(.evBodyLarge)
                    .foregroundStyle(Color.evOutline)
                Spacer()
            }
            Spacer()
        }
        .padding(.horizontal, Spacing.xl)
        .padding(.top, Spacing.section)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.evSurface)
    }
}
