import SwiftUI

struct HomeView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xl) {
            Text("Home")
                .font(.evHeadlineLarge)
                .foregroundStyle(Color.evPrimary)
            Text("At-a-glance view of your family's day")
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
