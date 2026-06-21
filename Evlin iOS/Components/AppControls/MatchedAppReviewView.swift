import SwiftUI
import FamilyControls
import ManagedSettings

/// The canonical "is this the same app?" side-by-side review, shared by the old
/// Add App flow (`CatalogBindRowView.confirmationBody`) and App Controls v2
/// (`AppControlsV2View.MatchedReviewPanel`) so BOTH render byte-for-byte identical.
///
/// Evlin can't read a token's name as text — it can only render `Label(token)`.
/// So this eyeball comparison is the only way to confirm the parent picked the
/// right App Store entry (e.g. not a knockoff):
/// - "iOS shows" = the system-rendered `Label(token)` (icon + label on-device).
/// - "You picked" = the artwork tile + canonical name the parent chose.
///
/// The caller passes the already-resolved `picked` result, so the proper-case
/// name + real artwork (or the letter-tile fallback) is the caller's concern —
/// this view just lays it out.
struct MatchedAppReviewView: View {
    let token: ApplicationToken
    let picked: CatalogSearchResult
    let onRebind: () -> Void

    init(
        token: ApplicationToken,
        picked: CatalogSearchResult,
        onRebind: @escaping () -> Void
    ) {
        self.token = token
        self.picked = picked
        self.onRebind = onRebind
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // The caption tells the parent WHY two near-identical rows are shown.
            // Stacked full-width rows keep long names from wrapping/truncating (the
            // old half-width columns did both — "WhatsApp" broke onto two lines).
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
                        CatalogArtworkView(result: picked, size: 24)
                        Text(picked.canonicalName)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                        Spacer(minLength: 0)
                    }
                }
            }
            .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))

            HStack {
                Spacer(minLength: 0)
                Button("Rebind") {
                    onRebind()
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
}

/// The app artwork tile for the "You picked" row: the real App Store icon when
/// `artworkURL` is present, otherwise a first-letter gradient tile. Defined here
/// (the single place) so both screens share the exact same artwork rendering.
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
