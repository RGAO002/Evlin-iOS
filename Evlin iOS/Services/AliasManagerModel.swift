import Foundation
import Combine

protocol AliasManagingClient {
    func fetchLazyTagCatalogTargets(
        childDeviceID: UUID,
        query: String?
    ) async throws -> [LazyTagCatalogTarget]

    func saveLazyTagAlias(
        familyID: UUID,
        childDeviceID: UUID,
        target: LazyTagCatalogTarget,
        alias: String
    ) async throws -> LazyTagCatalogTarget

    func removeLazyTagAlias(
        familyID: UUID,
        childDeviceID: UUID,
        target: LazyTagCatalogTarget,
        alias: String
    ) async throws -> LazyTagCatalogTarget

    func renameLazyTagAlias(
        familyID: UUID,
        childDeviceID: UUID,
        target: LazyTagCatalogTarget,
        oldAlias: String,
        newAlias: String
    ) async throws -> LazyTagCatalogTarget
}

@MainActor
final class AliasManagerModel: ObservableObject {
    @Published private(set) var targets: [LazyTagCatalogTarget] = []
    @Published private(set) var isLoading = false
    @Published var errorMessage: String?
    @Published var searchText = ""

    let familyID: UUID
    let childDeviceID: UUID
    private let client: AliasManagingClient

    init(
        familyID: UUID,
        childDeviceID: UUID,
        client: AliasManagingClient
    ) {
        self.familyID = familyID
        self.childDeviceID = childDeviceID
        self.client = client
    }

    var sections: [LazyTagCatalogSection] {
        LazyTagCatalogModel.sections(from: targets, searchText: searchText)
    }

    func load() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            targets = try await client.fetchLazyTagCatalogTargets(
                childDeviceID: childDeviceID,
                query: nil
            )
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func addAlias(_ alias: String, to target: LazyTagCatalogTarget) async {
        errorMessage = nil
        do {
            let updated = try await client.saveLazyTagAlias(
                familyID: familyID,
                childDeviceID: childDeviceID,
                target: target,
                alias: alias
            )
            replaceTarget(updated)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func removeAlias(_ alias: String, from target: LazyTagCatalogTarget) async {
        errorMessage = nil
        do {
            let updated = try await client.removeLazyTagAlias(
                familyID: familyID,
                childDeviceID: childDeviceID,
                target: target,
                alias: alias
            )
            replaceTarget(updated)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func renameAlias(_ oldAlias: String, to newAlias: String, for target: LazyTagCatalogTarget) async {
        errorMessage = nil
        do {
            let updated = try await client.renameLazyTagAlias(
                familyID: familyID,
                childDeviceID: childDeviceID,
                target: target,
                oldAlias: oldAlias,
                newAlias: newAlias
            )
            replaceTarget(updated)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func replaceTarget(_ updated: LazyTagCatalogTarget) {
        guard let idx = targets.firstIndex(where: { $0.aliasKey == updated.aliasKey }) else {
            targets.append(updated)
            return
        }
        targets[idx] = updated
    }
}

extension APIClient: AliasManagingClient {}
