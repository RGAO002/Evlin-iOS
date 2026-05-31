// Evlin iOS/Services/LazyTagPersistence.swift
//
// Pure persistence helper for lazy tag. No UI, no presentation. Validates
// that the token type matches the kind, then delegates to LocalAliasStore.

import Foundation
import FamilyControls
import ManagedSettings

enum LazyTagError: Error, Equatable {
    case wrongTokenType
    case emptyTarget
    case missingChildDevice
    case saveFailed
}

enum LazyTagPersistence {
    static func normalizedAlias(_ target: String) -> Result<String, LazyTagError> {
        let trimmed = target.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .failure(.emptyTarget) }
        return .success(trimmed)
    }

    @MainActor
    static func persistCatalogAlias(
        target: LazyTagCatalogTarget,
        requestedAlias: String,
        childDeviceID: UUID?,
        apiClient: APIClient? = nil
    ) async -> Result<Void, LazyTagError> {
        guard let childDeviceID else { return .failure(.missingChildDevice) }
        switch normalizedAlias(requestedAlias) {
        case .failure(let error):
            return .failure(error)
        case .success(let alias):
            do {
                let client = apiClient ?? APIClient()
                _ = try await client.saveLazyTagAlias(
                    childDeviceID: childDeviceID,
                    aliasKey: target.aliasKey,
                    alias: alias
                )
                return .success(())
            } catch {
                return .failure(.saveFailed)
            }
        }
    }

    static func persistAlias(
        token: Any,
        kind: AliasKind,
        target: String
    ) -> Result<Void, LazyTagError> {
        let trimmed: String
        switch normalizedAlias(target) {
        case .failure(let error):
            return .failure(error)
        case .success(let alias):
            trimmed = alias
        }

        if token is LazyTagCatalogTarget {
            // Catalog-backed lazy-tag saves the alias via backend CRUD before
            // calling ChatViewModel. This success keeps legacy selection flow
            // clearing intact without writing a parent-local token alias.
            return .success(())
        }

        switch kind {
        case .app:
            guard let appToken = token as? ApplicationToken else {
                return .failure(.wrongTokenType)
            }
            LocalAliasStore.shared.saveApplicationAliases(
                token: appToken,
                displayName: trimmed,
                bundleIdentifier: nil
            )
            return .success(())
        case .category:
            guard let catToken = token as? ActivityCategoryToken else {
                return .failure(.wrongTokenType)
            }
            LocalAliasStore.shared.saveCategoryToken(catToken, forName: trimmed)
            return .success(())
        }
    }
}
