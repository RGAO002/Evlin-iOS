import SwiftUI
import FamilyControls

/// App Controls v2 combined picker. Unlike the single-mode Add App / Add List
/// sheets, this keeps BOTH apps and categories in one `FamilyActivitySelection`
/// (no single-app gate, no category rejection). Validation runs on Save via
/// `CombinedPickerValidator`; an invalid selection surfaces an inline warning and
/// keeps the sheet open.
///
/// This sheet owns its own `@State` selection. It deliberately does NOT touch
/// `ScreenTimeManager.selectedApps` (that legacy store is built with
/// `includeEntireCategory: true`); here we require `includeEntireCategory: false`.
struct CombinedPickerSheet: View {
    private let onSave: (FamilyActivitySelection) -> Void
    private let onCancel: () -> Void

    @State private var selection: FamilyActivitySelection
    @State private var errorText: String?

    init(
        initialSelection: FamilyActivitySelection? = nil,
        onSave: @escaping (FamilyActivitySelection) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.onSave = onSave
        self.onCancel = onCancel

        // CRITICAL: start from a fresh `includeEntireCategory: false` selection.
        // Assigning `initialSelection` directly would round-trip through
        // FamilyActivitySelection's Codable, which drops the
        // `includeEntireCategory` flag and reverts the picker to its default
        // (entire-category) behavior. Copy only the token sets onto the fresh
        // value so the flag is preserved.
        var seed = FamilyActivitySelection(includeEntireCategory: false)
        if let initialSelection {
            seed.applicationTokens = initialSelection.applicationTokens
            seed.categoryTokens = initialSelection.categoryTokens
            seed.webDomainTokens = initialSelection.webDomainTokens
        }
        _selection = State(initialValue: seed)
    }

    var body: some View {
        VStack(spacing: 0) {
            FamilyActivityPicker(selection: $selection)

            if let errorText {
                CombinedPickerErrorToast(message: errorText)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 12)
            }

            Button(action: attemptSave) {
                Text("Save")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(Color.evPrimary, in: Capsule())
                    .foregroundStyle(.white)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 12)

            Button(action: onCancel) {
                Text("Cancel")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.evOnSurface)
            .padding(.horizontal, 24)
            .padding(.bottom, 20)
        }
        .presentationDetents([.large])
    }

    private func attemptSave() {
        let result = CombinedPickerValidator.validate(SelectionCounts(selection))
        guard result.isValid else {
            errorText = result.reason?.rawValue
            return
        }
        errorText = nil
        onSave(selection)
    }
}

private struct CombinedPickerErrorToast: View {
    let message: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
            Text(message)
                .font(.subheadline.weight(.semibold))
        }
        .foregroundStyle(Color.evError)
        .padding(16)
        .frame(maxWidth: .infinity)
        .background(
            Color.evError.opacity(0.12),
            in: RoundedRectangle(cornerRadius: 18, style: .continuous)
        )
    }
}
