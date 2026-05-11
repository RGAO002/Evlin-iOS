import SwiftUI
import FamilyControls

/// Inline readout of what `FamilyActivityPicker` stored — useful while learning
/// tap targets (category row vs individual apps vs whole domain).
struct ManagedActivitySelectionDiagnostics: View {
    let selection: FamilyActivitySelection

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Selection diagnostics")
                .font(.custom("Inter", size: 11).weight(.bold))
                .tracking(0.8)
                .foregroundStyle(Color.evOutline)

            row(label: "includeEntireCategory", value: selection.includeEntireCategory ? "true" : "false")
            row(label: "applicationTokens", value: "\(selection.applicationTokens.count)")
            row(label: "categoryTokens", value: "\(selection.categoryTokens.count)")
            row(label: "webDomainTokens", value: "\(selection.webDomainTokens.count)")
            Divider().opacity(0.35)
            row(label: "applications (metadata)", value: "\(selection.applications.count)")
            row(label: "categories (metadata)", value: "\(selection.categories.count)")
            Text("Semantic keys (games / social / entertainment …) are rebuilt from a saved label snapshot when categories (metadata) shows 0 — common after relaunch. If chat says not configured, update the app, then open Managed Apps once and dismiss the picker to refresh the snapshot.")
                .font(.custom("Inter", size: 10))
                .foregroundStyle(Color.evOnSurfaceVariant)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.evSurfaceContainerLow)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func row(label: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Color.evOnSurfaceVariant)
            Spacer(minLength: 8)
            Text(value)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(Color.evOnSurface)
        }
    }
}
