import SwiftUI

struct LibraryView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xl) {
            Text("Library")
                .font(.evHeadlineLarge)
                .foregroundStyle(Color.evPrimary)
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
