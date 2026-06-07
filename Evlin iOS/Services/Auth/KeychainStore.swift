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
/// (service, account="session"), with kSecAttrAccessibleAfterFirstUnlock so
/// the app can refresh in the background after the first device unlock.
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
        attrs[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
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
