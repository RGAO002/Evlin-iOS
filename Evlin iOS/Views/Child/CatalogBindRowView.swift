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

    @State private var query = ""
    @State private var results: [CatalogSearchResult] = []
    @State private var searching = false
    @State private var searchTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let entry = row.boundEntry {
                confirmationBody(entry)
            } else {
                namingBody
            }
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
                    .labelStyle(.iconOnly)
                Text("Which app is this?")
                    .font(.subheadline.weight(.medium))
                Spacer(minLength: 8)
            }

            Text("Evlin can show the icon but can't read the name. Match it to the App Store so a parent can lock it by name later.")
                .font(.caption)
                .foregroundStyle(.secondary)

            TextField("Match it to the App Store, e.g. TikTok", text: $query)
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

            ForEach(results) { result in
                Button {
                    row.bind(result)
                    query = result.canonicalName
                    results = []
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(result.canonicalName)
                        if let bundleID = result.bundleID {
                            Text(bundleID)
                                .font(.caption2.monospaced())
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    @ViewBuilder
    private func confirmationBody(_ entry: CatalogSearchResult) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Label(token)
                    .labelStyle(.titleAndIcon)
                    .lineLimit(1)
                Spacer(minLength: 8)
                if row.isLockableApp {
                    Image(systemName: "checkmark.seal.fill")
                        .foregroundStyle(.green)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Catalog match: \(entry.canonicalName)\(entry.bundleID.map { " · \($0)" } ?? "")")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if row.confirmed {
                    HStack {
                        Text("Confirmed")
                            .font(.caption)
                            .foregroundStyle(.green)
                        Button("Rebind") {
                            rebind()
                        }
                        .font(.caption)
                    }
                } else {
                    Text("Do these match? The app above should be \(entry.canonicalName).")
                        .font(.caption)
                    HStack {
                        Button("Yes, they match") {
                            row.confirm()
                        }
                        .buttonStyle(.borderedProminent)

                        Button("No, rebind") {
                            rebind()
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }
        }
    }

    private func rebind() {
        row = PendingAppRow(
            rowID: row.id,
            tokenBase64: row.tokenBase64,
            tokenAvailable: row.tokenAvailable
        )
        query = ""
        results = []
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
