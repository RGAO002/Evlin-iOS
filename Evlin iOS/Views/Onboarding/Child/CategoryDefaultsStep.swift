import SwiftUI
import FamilyControls

/// Child picks the ActivityCategoryTokens that the parent should be allowed to
/// control via Chat (e.g. "lock all games"). Category names are auto-assigned
/// as "category_1", "category_2" etc. since SwiftUI Label(token) doesn't expose
/// the human-readable name back to us. Parent/child can rename later in Settings.
struct CategoryDefaultsStep: View {
    let onContinue: () -> Void

    @State private var selection = FamilyActivitySelection()
    @State private var showPicker = false
    @State private var saved = false

    var body: some View {
        VStack(spacing: Spacing.section) {
            VStack(spacing: Spacing.lg) {
                Text("Category Defaults")
                    .font(.evHeadlineLarge)
                    .foregroundStyle(Color.evPrimary)
                Text("Pick which categories your parent should be able to control via Chat (e.g. 'lock all games').")
                    .font(.evBodyMedium)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(Color.evOnSurfaceVariant)
                    .padding(.horizontal, Spacing.xl)
            }
            .padding(.top, Spacing.section)

            Button {
                showPicker = true
            } label: {
                Text("Open Category Picker")
                    .font(.evLabelLarge)
                    .foregroundStyle(Color.evPrimary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, Spacing.lg)
                    .background(
                        RoundedRectangle(cornerRadius: CornerRadius.md)
                            .fill(Color.evSurfaceContainerLow)
                            .evGhostBorder()
                    )
            }
            .buttonStyle(.plain)
            .familyActivityPicker(isPresented: $showPicker, selection: $selection)

            Text("\(selection.categoryTokens.count) categories selected")
                .font(.evLabelMedium)
                .foregroundStyle(Color.evOnSurfaceVariant)
                .evLabelStyle()

            Spacer()

            Button {
                saveCategories()
                onContinue()
            } label: {
                Text("Continue")
                    .font(.evLabelLarge)
                    .frame(maxWidth: .infinity)
            }
            .foregroundStyle(Color.evOnPrimary)
            .padding(.vertical, Spacing.lg)
            .background(
                RoundedRectangle(cornerRadius: CornerRadius.md)
                    .fill(selection.categoryTokens.isEmpty ? Color.evOutline : Color.evPrimary)
            )
            .disabled(selection.categoryTokens.isEmpty)
        }
        .padding(Spacing.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.evSurface)
    }

    private func saveCategories() {
        // Note: we can't read the human category name from the token, so we assign
        // positional names. Parent Chat's AI classifies targets into semantic
        // categories (games/social/...) — the child device then needs to know
        // which of its picked tokens corresponds to which name. For MVP, we
        // save each under the default "category_N" key; a future Settings page
        // lets user rename per token.
        for (i, tok) in selection.categoryTokens.enumerated() {
            LocalAliasStore.shared.saveCategoryToken(tok, forName: "category_\(i + 1)")
        }
        saved = true
    }
}
