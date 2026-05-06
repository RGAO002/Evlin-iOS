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
}

enum LazyTagPersistence {
    static func persistAlias(
        token: Any,
        kind: AliasKind,
        target: String
    ) -> Result<Void, LazyTagError> {
        let trimmed = target.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .failure(.emptyTarget) }

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
