import Foundation
import Security

/// Keychain MIRROR for the device identity UUIDs. UserDefaults stays the
/// runtime interface (every existing reader keeps using `evlin.parentDeviceID`
/// / `evlin.childDeviceID` unchanged); the Keychain copy survives app deletion
/// so a reinstall re-attaches to the same backend device instead of minting a
/// new id and losing usage. Sign-out/reset MUST call `clear()`, else a
/// logged-out identity resurrects on next launch.
final class DeviceIdentity {
    static let shared = DeviceIdentity(defaults: .standard, keychainService: "com.evlin.deviceid")

    static let parentKey = "evlin.parentDeviceID"
    static let childKey = "evlin.childDeviceID"

    private let defaults: UserDefaults
    private let service: String

    init(defaults: UserDefaults, keychainService: String) {
        self.defaults = defaults
        self.service = keychainService
    }

    /// Launch: UserDefaults wins when present (fresh backend value → mirror it);
    /// otherwise restore from the Keychain mirror (reinstall recovery).
    func hydrate() {
        for key in [Self.parentKey, Self.childKey] {
            let ud = validUUID(defaults.string(forKey: key))
            let kc = validUUID(keychainGet(account: key))
            if let ud {
                if ud != kc { keychainSet(ud, account: key) }
            } else if let kc {
                defaults.set(kc, forKey: key)
            }
        }
    }

    /// Background: mirror whatever UserDefaults currently holds into Keychain.
    func capture() {
        for key in [Self.parentKey, Self.childKey] {
            if let ud = validUUID(defaults.string(forKey: key)) {
                keychainSet(ud, account: key)
            }
        }
    }

    /// Sign-out / reset: drop the mirror so a logged-out identity does not
    /// resurrect on next launch.
    func clear() {
        for key in [Self.parentKey, Self.childKey] { keychainDelete(account: key) }
    }

    private func validUUID(_ s: String?) -> String? {
        guard let s, UUID(uuidString: s) != nil else { return nil }
        return s
    }

    private func baseQuery(account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }
    private func keychainGet(account: String) -> String? {
        var q = baseQuery(account: account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
    private func keychainSet(_ value: String, account: String) {
        SecItemDelete(baseQuery(account: account) as CFDictionary)
        var attrs = baseQuery(account: account)
        attrs[kSecValueData as String] = Data(value.utf8)
        SecItemAdd(attrs as CFDictionary, nil)
    }
    private func keychainDelete(account: String) {
        SecItemDelete(baseQuery(account: account) as CFDictionary)
    }
}
