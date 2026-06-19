import SwiftUI
import FamilyControls
import ManagedSettings

/// One pending app row in the Add App flow.
///
/// Naming step shows the system-rendered app token icon only. Evlin cannot read
/// the rendered app name as text, so the parent matches the icon to an App Store
/// catalog result. Picking that result immediately marks the token lockable by
/// name; the row then shows a side-by-side review (with a Rebind escape) instead
/// of a blocking "do these match?" confirmation prompt.
struct CatalogBindRowView: View {
    let token: ApplicationToken
    @Binding var row: PendingAppRow
    let apiClient: APIClient
    var isHighlighted: Bool = false

    @State private var inlineError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let entry = row.boundEntry {
                confirmationBody(entry)
            } else {
                namingBody
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(isHighlighted ? Color.orange.opacity(0.12) : Color.clear)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(isHighlighted ? Color.orange.opacity(0.6) : Color.clear, lineWidth: 1)
        }
        .padding(.vertical, 6)
    }

    private var namingBody: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Label(token)
                    .labelStyle(.titleAndIcon)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Spacer(minLength: 8)
            }

            AppStoreBindPanel(
                appName: appLabelText,
                apiClient: apiClient,
                onPick: { result in
                    // Picking the matching App Store result IS the confirmation —
                    // the parent has been looking at Label(token) (shown above) the
                    // whole time they searched. No separate "yes these match" tap.
                    row.bind(result)
                    row.confirm()
                    inlineError = nil
                },
                onManual: { manualName in
                    row.bind(CatalogSearchResult(canonicalName: manualName, bundleID: nil, aliases: []))
                    row.confirm()
                    inlineError = nil
                }
            )
        }
    }

    /// The iOS label is not readable as text, so the unified copy refers to the
    /// app generically. Kept here so the panel's copy reads naturally.
    private var appLabelText: String {
        "this app"
    }

    @ViewBuilder
    private func confirmationBody(_ entry: CatalogSearchResult) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.title3)
                    .foregroundStyle(.green)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(entry.canonicalName) is lockable")
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    Text("This app can now be locked by name.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }

            // Evlin can't read the token's name as text — it can only render
            // Label(token). So this eyeball comparison is the only way to confirm the
            // parent picked the right App Store entry (e.g. not a knockoff). The
            // caption tells them WHY two near-identical rows are shown. Stacked
            // full-width rows keep long names from wrapping/truncating (the old
            // half-width columns did both — "WhatsApp" broke onto two lines).
            Text("Double-check it's the same app:")
                .font(.caption)
                .foregroundStyle(.secondary)

            VStack(spacing: 0) {
                matchRow(label: "iOS shows") {
                    Label(token)
                        .labelStyle(.titleAndIcon)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
                Divider().padding(.leading, 12)
                matchRow(label: "You picked") {
                    HStack(spacing: 8) {
                        CatalogArtworkView(result: entry, size: 24)
                        Text(entry.canonicalName)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                        Spacer(minLength: 0)
                    }
                }
            }
            .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))

            if let inlineError {
                InlineCaptureError(message: inlineError)
            }

            HStack {
                Spacer(minLength: 0)
                Button("Rebind") {
                    rebind()
                }
                .font(.caption.weight(.semibold))
            }
        }
    }

    /// One full-width row of the "do these match?" cross-check: a fixed-width
    /// caption ("iOS shows" / "You picked") followed by the app representation.
    /// Full width means long app names never wrap or truncate.
    @ViewBuilder
    private func matchRow<Content: View>(
        label: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(spacing: 12) {
            Text(label)
                .font(.caption2.weight(.bold))
                .foregroundStyle(.secondary)
                .frame(width: 64, alignment: .leading)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private func rebind() {
        row = PendingAppRow(
            rowID: row.id,
            tokenBase64: row.tokenBase64,
            tokenAvailable: row.tokenAvailable
        )
        inlineError = nil
    }
}

private struct CatalogArtworkView: View {
    let result: CatalogSearchResult
    let size: CGFloat

    var body: some View {
        Group {
            if let url = result.artworkURL {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .scaledToFill()
                    default:
                        fallbackIcon
                    }
                }
            } else {
                fallbackIcon
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size <= 30 ? 8 : 10, style: .continuous))
    }

    private var fallbackIcon: some View {
        RoundedRectangle(cornerRadius: size <= 30 ? 8 : 10, style: .continuous)
            .fill(iconFill)
            .overlay {
                Text(String(result.canonicalName.prefix(1)).uppercased())
                    .font(.caption.weight(.black))
                    .foregroundStyle(.white)
            }
    }

    private var iconFill: LinearGradient {
        LinearGradient(
            colors: result.bundleID == nil ? [.gray.opacity(0.7), .gray] : [.orange, .pink, .purple],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}

private struct InlineCaptureError: View {
    let message: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .font(.caption.weight(.semibold))
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}
