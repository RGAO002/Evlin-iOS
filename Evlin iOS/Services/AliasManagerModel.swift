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
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            rows = try await client.fetchAppAliases(familyID: familyID)
        } catch {
            errorMessage = error.localizedDescription
        }
        // Best-effort: fetch child devices so the view can pick a real device ID
        // when presenting AddAppFlowView for block-only apps. A failure here must
        // NOT disrupt the alias list — alias rows remain visible regardless.
        childDevices = (try? await client.fetchParentChildDevices(familyID: familyID)) ?? []
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
