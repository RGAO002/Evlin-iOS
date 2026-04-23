import SwiftUI

struct ChildFirstSavedListStep: View {
    @EnvironmentObject var apiClient: APIClient
    let familyID: UUID
    let childDeviceID: UUID
    let onContinue: () -> Void

    @State private var created: String?

    var body: some View {
        VStack(spacing: 16) {
            Text("Your First Saved List")
                .font(.evHeadlineLarge)
                .padding(.top, 20)
            Text("Build a list your parent can reference by name in Chat, e.g. 'lock list 1 for 30 min'.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal)
            if let name = created {
                Label("'\(name)' saved", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Button(action: onContinue) {
                    Text("Continue").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .padding(.horizontal)
            } else {
                SavedListPickerView(
                    familyID: familyID,
                    owningDeviceID: childDeviceID,
                    mode: "child_device"
                ) { name in
                    created = name
                }
                Button("Skip for now", action: onContinue).padding(.top)
            }
        }
    }
}
