import SwiftUI

/// Reusable inline naming panel: an App Store search field + live results list +
/// a "save manually" escape hatch. Apple won't expose the rendered app name as
/// text, so the parent matches the icon to an App Store catalog entry by hand.
///
/// Extracted from `CatalogBindRowView.namingBody` so App Controls v2 can embed the
/// SAME naming UI inside an accordion. The host owns what happens on pick/manual
/// (bind + confirm + side-effects) via the callbacks; this view owns only the
/// search query state and the debounced catalog lookup.
struct AppStoreBindPanel: View {
    /// The iOS-rendered app label, used only in the explanatory copy.
    let appName: String
    let apiClient: APIClient
    /// Parent picked a real App Store catalog result.
    let onPick: (CatalogSearchResult) -> Void
    /// Parent gave up on a match and wants to save by the typed name.
    let onManual: (String) -> Void

    @State private var query = ""
    @State private var results: [CatalogSearchResult] = []
    @State private var searching = false
    @State private var searchTask: Task<Void, Never>?
    @State private var inlineError: String?

    init(
        appName: String,
        apiClient: APIClient,
        onPick: @escaping (CatalogSearchResult) -> Void,
        onManual: @escaping (String) -> Void
    ) {
        self.appName = appName
        self.apiClient = apiClient
        self.onPick = onPick
        self.onManual = onManual
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text("We know it's a hassle, but Apple won't let Evlin read app names — it can only show you the iOS label.")
                    .fixedSize(horizontal: false, vertical: true)
                Text("To give your agents full control, search below and pick the matching App Store result. You’ll only have to do this once.")
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            TextField("Search matching App Store app, e.g. TikTok", text: $query)
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .onChange(of: query) { _, newValue in
                    scheduleSearch(newValue)
                }

            if searching {
                ProgressView()
                    .controlSize(.small)
            }

            if let inlineError {
                AppStoreBindInlineError(message: inlineError)
            }

            ForEach(results) { result in
                Button {
                    // Picking the matching App Store result IS the confirmation —
                    // the parent has been looking at the app label the whole time
                    // they searched. No separate "yes these match" tap.
                    onPick(result)
                    query = result.canonicalName
                    results = []
                    inlineError = nil
                } label: {
                    AppStoreCandidateRow(result: result)
                }
                .buttonStyle(.plain)
            }

            if query.trimmingCharacters(in: .whitespacesAndNewlines).count >= 2,
               searching == false,
               results.isEmpty {
                Button("No App Store match - save manually") {
                    let manualName = query.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard manualName.isEmpty == false else {
                        inlineError = "Type a name before saving manually."
                        return
                    }
                    onManual(manualName)
                    inlineError = nil
                }
                .font(.caption.weight(.semibold))
            }
        }
        .onDisappear {
            searchTask?.cancel()
        }
    }

    private func scheduleSearch(_ text: String) {
        searchTask?.cancel()
        let q = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard q.count >= 2 else {
            results = []
            searching = false
            return
        }

        searchTask = Task {
            try? await Task.sleep(nanoseconds: 250_000_000)
            if Task.isCancelled { return }
            await MainActor.run {
                searching = true
            }
            let dtos = (try? await apiClient.catalogSearch(q: q)) ?? []
            if Task.isCancelled { return }
            await MainActor.run {
                results = dtos.map(\.result)
                searching = false
            }
        }
    }
}

/// One App Store search result row: artwork + canonical name + bundle id (or a
/// "Manual" badge when the parent is naming an app with no catalog match).
struct AppStoreCandidateRow: View {
    let result: CatalogSearchResult
    var compact = false

    var body: some View {
        HStack(spacing: 10) {
            AppStoreArtworkView(result: result, size: compact ? 30 : 34)

            VStack(alignment: .leading, spacing: 2) {
                Text(result.canonicalName)
                    .font(compact ? .caption.weight(.semibold) : .subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                if let bundleID = result.bundleID {
                    Text(bundleID)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else {
                    Text("Manual")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 0)

            if result.bundleID != nil {
                Text("match")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.green)
            } else {
                Text("Manual")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(compact ? 0 : 10)
        .background(compact ? Color.clear : Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

/// Catalog artwork with a gradient-initial fallback. Manual (bundle-less) entries
/// fall back to a neutral grey; real matches use the warm Evlin gradient.
struct AppStoreArtworkView: View {
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

private struct AppStoreBindInlineError: View {
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
