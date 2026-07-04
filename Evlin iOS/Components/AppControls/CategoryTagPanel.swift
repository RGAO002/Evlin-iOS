import SwiftUI

/// Reusable inline category-tagging panel: the `AppleScreenTimeCategorySuggestions`
/// capsule grid. Apple won't expose the picker's category name as text, so the
/// parent taps the matching Screen Time category to make the token lockable by name.
///
/// Extracted from `CategoryBindRowView` so App Controls v2 can embed the SAME
/// tagging UI inside an accordion. The host maps the panel's stateless interface
/// onto `PendingCategoryRow`: `selectedKey` comes from the row's current semantic
/// key, and `onPick` drives `applySuggestion`. That preserves the existing
/// `applySuggestion` / `matchesSuggestion` tagging semantics exactly.
struct CategoryTagPanel: View {
    /// The iOS-rendered category label, used only in the explanatory copy.
    let name: String
    /// The semantic key of the currently-applied suggestion, or nil if none.
    /// A capsule is shown selected when its `semanticKey` equals this value.
    let selectedKey: String?
    /// Parent tapped a category capsule.
    let onPick: (AppleScreenTimeCategorySuggestion) -> Void

    init(
        name: String,
        selectedKey: String?,
        onPick: @escaping (AppleScreenTimeCategorySuggestion) -> Void
    ) {
        self.name = name
        self.selectedKey = selectedKey
        self.onPick = onPick
    }

    private var suggestions: [AppleScreenTimeCategorySuggestion] {
        AppleScreenTimeCategorySuggestions.visibleCapsules(for: name)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                Text("We know it's a hassle, but Apple won't let Evlin read category names — it can only show you the iOS label.")
                    .fixedSize(horizontal: false, vertical: true)
                Text("To give your agents full control, just tap on the matching tag by name. You’ll only have to do this once!")
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(.caption)
            .foregroundStyle(Color.evOnSurfaceVariant)

            if !suggestions.isEmpty {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 128), spacing: 8, alignment: .leading)],
                    alignment: .leading,
                    spacing: 8
                ) {
                    ForEach(suggestions) { suggestion in
                        let selected = suggestion.semanticKey == selectedKey
                        Button {
                            onPick(suggestion)
                        } label: {
                            Text(suggestion.displayName)
                                .font(.caption.weight(.semibold))
                                .lineLimit(2)
                                .multilineTextAlignment(.center)
                                .foregroundStyle(selected ? Color.white : Color.evPrimary)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 8)
                                .frame(maxWidth: .infinity, minHeight: 34)
                                .background(
                                    selected ? Color.evPrimary : Color.evPrimaryContainer,
                                    in: Capsule()
                                )
                                .overlay {
                                    Capsule()
                                        .stroke(selected ? Color.evPrimary : Color.evOutlineVariant, lineWidth: 1)
                                }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }
}
