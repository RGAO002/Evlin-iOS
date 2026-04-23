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
        VStack(spacing: 16) {
            Text("Category Defaults")
                .font(.evHeadlineLarge)
                .padding(.top, 40)
            Text("Pick which categories your parent should be able to control via Chat (e.g. 'lock all games').")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal)

            Button("Open Category Picker") { showPicker = true }
                .buttonStyle(.borderedProminent)
                .familyActivityPicker(isPresented: $showPicker, selection: $selection)

            Text("\(selection.categoryTokens.count) categories selected")
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer()

            Button {
                saveCategories()
                onContinue()
            } label: {
                Text("Continue").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(selection.categoryTokens.isEmpty)
        }
        .padding()
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
