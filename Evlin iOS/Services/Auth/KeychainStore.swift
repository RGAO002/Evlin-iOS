import Foundation
import Security

/// The session tokens persisted on this device. Tokens are SECRETS — they
/// live in the Keychain (not UserDefaults). §6.1 / §14.8: main-app-only,
/// NO shared keychain access group (the 3 extensions never make authed calls
/// and share state via the App Group, so the token never needs to reach them).
struct StoredTokens: Codable, Equatable {
    var accessToken: String
    var refreshToken: String
    var accountID: String
    // Persist the WHOLE auth account (§15.7): familyID + displayName are NOT
    // discarded, so a Keychain restore can rebuild the canonical AuthAccountDTO
    // (membership/display) without a network round-trip.
    var familyID: String?
    var displayName: String?
    var needsFamily: Bool
}

/// Keychain-backed token store. Item is a single JSON blob keyed by
/// (service, account="session"), with kSecAttrAccessibleAfterFirstUnlock**ThisDeviceOnly**
/// so the app can still refresh in the background after the first device unlock,
/// while the session secret is EXCLUDED from iCloud/iTunes/encrypted backups and
/// device-to-device migration. A long-lived refresh token must not survive a
/// restore onto a different device (would enable persistent account hijack);
/// the ThisDeviceOnly variant keeps it bound to this hardware.
final class KeychainStore {
    static let shared = KeychainStore(service: "com.evlin.session")

    private let service: String
    private let account = "session"

    init(service: String) {
        self.service = service
    }

    func save(_ tokens: StoredTokens) throws {
        let data = try JSONEncoder().encode(tokens)
        // Delete any existing item first so we don't hit errSecDuplicateItem.
        SecItemDelete(baseQuery() as CFDictionary)
        var attrs = baseQuery()
        attrs[kSecValueData as String] = data
        attrs[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(attrs as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    func load() -> StoredTokens? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return try? JSONDecoder().decode(StoredTokens.self, from: data)
    }

    /// Outcome of a Keychain read that distinguishes "no session on file" from
    /// "the Keychain was momentarily unreadable". The bare `load()` collapses
    /// both into `nil`, which is wrong for the refresher: a transient read error
    /// (e.g. the item is briefly unavailable before first unlock) must NOT be
    /// treated as a sign-out, or a perfectly valid session gets discarded.
    enum LoadResult: Equatable {
        /// A session blob was present and decoded cleanly.
        case found(StoredTokens)
        /// No session is stored (item not found, or present but undecodable —
        /// either way there is nothing usable, so the user is signed out).
        case notFound
        /// The Keychain returned an unexpected status; the read may succeed on a
        /// later attempt. Callers should treat this as transient, NOT a sign-out.
        case unreadable(OSStatus)
    }

    /// Like `load()`, but reports WHY a read produced no tokens so callers can
    /// tell a genuine sign-out apart from a transient Keychain failure.
    func loadResult() -> LoadResult {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data,
                  let tokens = try? JSONDecoder().decode(StoredTokens.self, from: data) else {
                // Present but unreadable/corrupt → nothing usable; treat as no session.
                return .notFound
            }
            return .found(tokens)
        case errSecItemNotFound:
            return .notFound
        default:
            return .unreadable(status)
        }
    }

    func clear() {
        SecItemDelete(baseQuery() as CFDictionary)
    }

    private func baseQuery() -> [String: Any] {
        // NOTE: deliberately NO kSecAttrAccessGroup — main-app-only (§14.8).
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    enum KeychainError: Error, Equatable {
        case unexpectedStatus(OSStatus)
    }
}
