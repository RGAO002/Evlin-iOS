import SwiftUI

struct ParentFirstSavedListStep: View {
    @EnvironmentObject var apiClient: APIClient
    let familyID: UUID
    let parentDeviceID: UUID
    let onDone: () -> Void

    @State private var created: String? = nil

    var body: some View {
        VStack(spacing: Spacing.xl) {
            VStack(spacing: Spacing.lg) {
                Text("First Saved List")
                    .font(.evHeadlineLarge)
                    .foregroundStyle(Color.evPrimary)
                Text("Optional — make your first Saved List from YOUR phone. You can always add more later.")
                    .font(.evBodyMedium)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(Color.evOnSurfaceVariant)
                    .padding(.horizontal, Spacing.xl)
            }
            .padding(.top, Spacing.section)

            if let name = created {
                HStack(spacing: Spacing.md) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Color.evSecondary)
                    Text("'\(name)' saved")
                        .font(.evLabelLarge)
                        .foregroundStyle(Color.evSecondary)
                }
                Button(action: onDone) {
                    Text("Continue")
                        .font(.evLabelLarge)
                        .frame(maxWidth: .infinity)
                }
                .foregroundStyle(Color.evOnPrimary)
                .padding(.vertical, Spacing.lg)
                .background(
                    RoundedRectangle(cornerRadius: CornerRadius.md)
                        .fill(Color.evPrimary)
                )
                .padding(.horizontal, Spacing.xl)
            } else {
                SavedListPickerView(
                    familyID: familyID,
                    owningDeviceID: parentDeviceID,
                    mode: "parent_device"
                ) { name in
                    created = name
                }
                Button(action: onDone) {
                    Text("Skip for now")
                        .font(.evLabelLarge)
                        .foregroundStyle(Color.evOnSurfaceVariant)
                }
                .padding(.top, Spacing.md)
            }

            Spacer()
        }
        .padding(Spacing.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.evSurface)
    }
}
