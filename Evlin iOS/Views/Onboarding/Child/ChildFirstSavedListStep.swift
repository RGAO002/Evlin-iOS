import SwiftUI

struct ChildFirstSavedListStep: View {
    @EnvironmentObject var apiClient: APIClient
    let familyID: UUID
    let childDeviceID: UUID
    let onContinue: () -> Void

    @State private var created: String?

    var body: some View {
        VStack(spacing: Spacing.xl) {
            VStack(spacing: Spacing.lg) {
                Text("Your First Saved List")
                    .font(.evHeadlineLarge)
                    .foregroundStyle(Color.evPrimary)
                Text("Build a list your parent can reference by name in Chat, e.g. 'lock list 1 for 30 min'.")
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
                Button(action: onContinue) {
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
                    owningDeviceID: childDeviceID,
                    mode: "child_device"
                ) { name in
                    created = name
                }
                Button(action: onContinue) {
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
