import SwiftUI

struct ParentFirstSavedListStep: View {
    @EnvironmentObject var apiClient: APIClient
    let familyID: UUID
    let parentDeviceID: UUID
    let onDone: () -> Void

    @State private var created: String? = nil

    var body: some View {
        VStack(spacing: 16) {
            Text("First Saved List")
                .font(.evHeadlineLarge)
                .padding(.top, 20)
            Text("Optional — make your first Saved List from YOUR phone. You can always add more later.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal)

            if let name = created {
                Text("✓ '\(name)' saved").foregroundStyle(.green).font(.headline)
                Button(action: onDone) {
                    Text("Continue").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .padding(.horizontal)
            } else {
                SavedListPickerView(
                    familyID: familyID,
                    owningDeviceID: parentDeviceID,
                    mode: "parent_device"
                ) { name in
                    created = name
                }
                Button("Skip for now", action: onDone)
                    .padding(.top)
            }
        }
    }
}
