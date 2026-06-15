import SwiftUI
import FamilyControls
import ManagedSettings

/// One pending app row in the Add App flow.
///
/// Naming step shows the system-rendered app token icon only. Evlin cannot read
/// the rendered app name as text, so the parent matches the icon to an App Store
/// catalog result. Confirmation then reveals the full `Label(token)` for a
/// visual "do these match?" check before the token becomes lockable by name.
struct CatalogBindRowView: View {
    let token: ApplicationToken
    @Binding var row: PendingAppRow
    let apiClient: APIClient
    var isHighlighted: Bool = false

    @State private var query = ""
    @State private var results: [CatalogSearchResult] = []
    @State private var searching = false
    @State private var searchTask: Task<Void, Never>?
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
        .onDisappear {
            searchTask?.cancel()
        }
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
                InlineCaptureError(message: inlineError)
            }

            ForEach(results) { result in
                Button {
                    row.bind(result)
                    query = result.canonicalName
                    results = []
                    inlineError = nil
                } label: {
                    CatalogCandidateRow(result: result)
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
                    row.bind(CatalogSearchResult(canonicalName: manualName, bundleID: nil, aliases: []))
                    inlineError = nil
                }
                .font(.caption.weight(.semibold))
            }
        }
    }

    @ViewBuilder
    private func confirmationBody(_ entry: CatalogSearchResult) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(row.isLockableApp ? "\(entry.canonicalName) is lockable" : "Do these match?")
                .font(.headline)

            Text(row.isLockableApp ? "This app can now be locked by name." : "Confirm the app iOS shows is the one you picked from the App Store.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 14) {
                VStack(spacing: 8) {
                    Text("iOS shows")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.secondary)
                    Label(token)
                        .labelStyle(.titleAndIcon)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                .frame(maxWidth: .infinity)

                Text("=?")
                    .font(.title3.weight(.black))
                    .foregroundStyle(.secondary)

                VStack(spacing: 8) {
                    Text("You picked")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.secondary)
                    CatalogCandidateRow(result: entry, compact: true)
                }
                .frame(maxWidth: .infinity)
            }
            .padding(12)
            .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 16, style: .continuous))

            if let inlineError {
                InlineCaptureError(message: inlineError)
            }

            if row.confirmed {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.seal.fill")
                        .foregroundStyle(.green)
                    Text("Ready")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.green)
                    Spacer(minLength: 8)
                    Button("Rebind") {
                        rebind()
                    }
                    .font(.caption)
                }
            } else {
                HStack {
                    Button("Yes, these match") {
                        row.confirm()
                        inlineError = nil
                    }
                    .buttonStyle(.borderedProminent)

                    Button("Pick a different app") {
                        inlineError = "Nothing was saved. Pick a different App Store match for this token."
                        rebind(keepError: true)
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
    }

    private func rebind(keepError: Bool = false) {
        let currentError = inlineError
        row = PendingAppRow(
            rowID: row.id,
            tokenBase64: row.tokenBase64,
            tokenAvailable: row.tokenAvailable
        )
        query = ""
        results = []
        inlineError = keepError ? currentError : nil
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

private struct CatalogCandidateRow: View {
    let result: CatalogSearchResult
    var compact = false

    var body: some View {
        HStack(spacing: 10) {
            CatalogArtworkView(result: result, size: compact ? 30 : 34)

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
