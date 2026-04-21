import SwiftUI

struct CalendarView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xl) {
            Text("Family Calendar")
                .font(.evHeadlineLarge)
                .foregroundStyle(Color.evPrimary)
            Text("Shared events, routines, and lock windows")
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
