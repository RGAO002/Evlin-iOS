import Foundation
import Combine

// MARK: - AliasManagerModel (Task F2)
//
// Family-scoped app-alias model. Keyed by familyID (not childDeviceID).
// Depends on AppAliasManagingClient (declared in APIClient.swift).
// All mutations call the server and re-fetch on success; on error the
// prior state is preserved and errorMessage is set (server-confirmed,
// NOT optimistic).

@MainActor
final class AliasManagerModel: ObservableObject {
    @Published private(set) var rows: [AppAliasRow] = []
    @Published private(set) var childDevices: [ParentChildDeviceSummaryDTO] = []
    @Published private(set) var isLoading = false
    @Published var errorMessage: String?
    @Published var searchText = ""

    let familyID: UUID
    private let client: AppAliasManagingClient
    /// The in-flight load. Cancelled when a newer load starts so the latest wins.
    private var loadTask: Task<Void, Never>?

    init(familyID: UUID, client: AppAliasManagingClient) {
        self.familyID = familyID
        self.client = client
    }

    // MARK: - Computed

    /// Rows filtered by searchText (case-insensitive match on canonicalName, bundleID, or any alias).
    var visibleRows: [AppAliasRow] {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return rows }
        return rows.filter { row in
            row.canonicalName.localizedCaseInsensitiveContains(q)
                || row.bundleID.localizedCaseInsensitiveContains(q)
                || row.aliases.contains { $0.localizedCaseInsensitiveContains(q) }
        }
    }

    // MARK: - Load

    func load() async {
        // `.task` (on appear) and `.refreshable` (pull) BOTH call this. Running the
        // fetch directly made the pull-to-refresh request get cancelled by the
        // competing task / the gesture teardown, so `rows` never updated and the user
        // had to leave + re-enter. Fix: cancel any in-flight load, then run the fetch
        // in an UNSTRUCTURED `Task` so a cancelled CALLER can't abort it — the newest
        // request always completes and updates `rows`.
        loadTask?.cancel()
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            self.isLoading = true
            defer { self.isLoading = false }
            do {
                self.rows = try await self.client.fetchAppAliases(familyID: self.familyID)
                self.errorMessage = nil
            } catch is CancellationError {
                // Superseded by a newer load — keep the existing rows.
            } catch let urlError as URLError where urlError.code == .cancelled {
                // Request cancelled by a newer refresh — keep the existing rows.
            } catch {
                self.errorMessage = error.localizedDescription
            }
            // Best-effort: fetch child devices so the view can pick a real device ID
            // when presenting AddAppFlowView for block-only apps. A failure here must
            // NOT disrupt the alias list — alias rows remain visible regardless.
            self.childDevices = (try? await self.client.fetchParentChildDevices(familyID: self.familyID)) ?? []
        }
        loadTask = task
        await task.value
    }

    // MARK: - Mutations (server-confirmed; re-fetch on success)

    func addAlias(_ alias: String, to row: AppAliasRow) async {
        errorMessage = nil
        do {
            try await client.addAppAlias(familyID: familyID, bundleID: row.bundleID, alias: alias)
            await load()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func removeAlias(_ alias: String, from row: AppAliasRow) async {
        errorMessage = nil
        do {
            try await client.removeAppAlias(familyID: familyID, bundleID: row.bundleID, alias: alias)
            await load()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func renameAlias(_ old: String, to new: String, for row: AppAliasRow) async {
        errorMessage = nil
        do {
            try await client.renameAppAlias(familyID: familyID, bundleID: row.bundleID, old: old, new: new)
            await load()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
