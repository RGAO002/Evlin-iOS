import SwiftUI

/// RETIRED STUB.
///
/// The original `.child` FamilyActivityPicker spike called the appID-only
/// catalog POC (`lockChildCatalogApp`), which the catalog-onboarding
/// consolidation removed. Reduced to this tombstone so the debug menus still
/// compile. The full original implementation is preserved in git history
/// (commit `a4cf66c` on `feat/three-tier-lock`). Use the real **Add App** flow
/// (`AddAppFlowView`) instead — it captures real tokens into the catalog.
struct ChildPickerSpikeView: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "wrench.and.screwdriver")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("Child picker spike retired")
                .font(.headline)
            Text("Superseded by the real Add App capture flow. Original spike code is in git history (a4cf66c).")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
        .navigationTitle("Picker spike (retired)")
    }
}
