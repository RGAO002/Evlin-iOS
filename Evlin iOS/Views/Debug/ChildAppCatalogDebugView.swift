import SwiftUI

/// RETIRED STUB.
///
/// The original debug inspector drove the appID-only catalog POC
/// (`lockChildCatalogApp` / `fetchChildAppCatalog` / `ChildAppCatalogEntryDTO`),
/// which the catalog-onboarding consolidation removed in favor of the real
/// resolver/lock contract. Keeping the live spike would mean resurrecting the
/// retired POC, so it's reduced to this tombstone — the debug menus still
/// compile. The full original implementation is preserved in git history
/// (commit `a4cf66c` on `feat/three-tier-lock`). Use the real **Add App** /
/// **Manage Lock List** flow instead.
struct ChildAppCatalogDebugView: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "wrench.and.screwdriver")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("Catalog debug retired")
                .font(.headline)
            Text("The appID-only catalog POC was replaced by the Add App / Manage Lock List flow. Original spike code is in git history (a4cf66c).")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
        .navigationTitle("Catalog debug (retired)")
    }
}
