import SwiftUI

/// RETIRED STUB.
///
/// The original one-page E2E probe extracted catalog entries from a
/// DeviceActivityReport snapshot via `LocalAliasStore.catalogEntriesFromReportSnapshot`
/// / `ReportCatalogExtractionResult` — the token-harvest spike that the catalog
/// onboarding consolidation replaced (codex's `LocalAliasStore` no longer exposes
/// those). Reduced to this tombstone so debug menus still compile. The full
/// original implementation is preserved in git history (commit `a4cf66c` on
/// `feat/three-tier-lock`). Use the real **Add App** capture flow instead.
struct AliasE2ETestView: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "wrench.and.screwdriver")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("Alias E2E probe retired")
                .font(.headline)
            Text("The DAR report-extraction token-harvest spike was superseded by the real capture flow. Original code is in git history (a4cf66c).")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
        .navigationTitle("Alias E2E (retired)")
    }
}
