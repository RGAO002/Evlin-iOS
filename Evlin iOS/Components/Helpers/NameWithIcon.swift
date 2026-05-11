import SwiftUI
import FamilyControls
import ManagedSettings

/// Render an app/category name with its real Apple icon when available,
/// SF Symbol fallback otherwise. The text part stays our own `Text` so
/// `.font` and `.foregroundColor` modifiers from the call-site work —
/// Apple's `Label(token)` text rendering ignores those.
///
/// Why a helper: ApplicationToken is opaque; only `Label(token)` can
/// render Apple's icon, and only `.labelStyle(.iconOnly)` strips the
/// ignored-style text part. Centralizes that two-step dance.
enum NameIconKind {
    case app
    case category
    case savedList
    case all
}

struct NameWithIcon: View {
    let name: String
    let kind: NameIconKind
    var titleFont: Font = .body

    var body: some View {
        HStack(spacing: 8) {
            iconView
                .frame(width: 24, height: 24)
            Text(NameWithIcon.displayName(name)).font(titleFont)
        }
    }

    /// Show the name with an uppercase first letter. `name` is preserved
    /// verbatim for icon-token lookup; only the rendered text is touched.
    /// Uses `prefix(1).uppercased() + dropFirst()` rather than `.capitalized`
    /// so multi-word names like "school apps" don't become "School Apps"
    /// (we only want first-letter capitalization, not title-case).
    static func displayName(_ name: String) -> String {
        guard !name.isEmpty else { return name }
        return name.prefix(1).uppercased() + name.dropFirst()
    }

    @ViewBuilder
    private var iconView: some View {
        switch kind {
        case .app:
            if let token = LocalAliasStore.shared.applicationToken(forLookupKey: name) {
                Label(token).labelStyle(.iconOnly)
            } else {
                Image(systemName: "app.fill")
                    .foregroundStyle(Color.evOutline)
            }
        case .category:
            if let token = LocalAliasStore.shared.categoryToken(forName: name) {
                Label(token).labelStyle(.iconOnly)
            } else {
                Image(systemName: "square.grid.2x2.fill")
                    .foregroundStyle(Color.evOutline)
            }
        case .savedList:
            Image(systemName: "list.bullet.rectangle.fill")
                .foregroundStyle(Color.evOutline)
        case .all:
            Image(systemName: "iphone")
                .foregroundStyle(Color.evOutline)
        }
    }
}

#if DEBUG
#Preview {
    VStack(alignment: .leading, spacing: 12) {
        NameWithIcon(name: "Instagram", kind: .app)
        NameWithIcon(name: "Entertainment", kind: .category)
        NameWithIcon(name: "Bedtime apps", kind: .savedList)
        NameWithIcon(name: "Whole phone", kind: .all)
    }
    .padding()
}
#endif
