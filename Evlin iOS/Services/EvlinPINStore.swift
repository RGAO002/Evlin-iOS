import CryptoKit
import Foundation
import Security

/// Evlin-managed edit-gate PIN, stored in the Keychain. This is deliberately
/// PIN-only: the kid's own biometric identity is enrolled on this device.
///
/// The Keychain value is `salt || sha256(salt || pinBytes)`. The raw PIN is
/// never persisted.
nonisolated final class EvlinPINStore {
    static let shared = EvlinPINStore(account: "evlin.editGatePIN")

    enum PINError: Error, Equatable {
        case invalidLength
        case keychainFailure(OSStatus)
    }

    static let minLength = 4
    static let maxLength = 8

    private let service = "com.evlin.ios.pin"
    private let account: String
    private let saltLength = 16

    init(account: String) {
        self.account = account
    }

    func isSet() -> Bool {
        readBlob() != nil
    }

    /// Stores `salt || sha256(salt || pin)`. Overwrites any existing PIN.
    func setPIN(_ pin: String) throws {
        let digits = pin.trimmingCharacters(in: .whitespaces)
        guard digits.count >= Self.minLength,
              digits.count <= Self.maxLength,
              Self.isASCIIDigits(digits) else {
            throw PINError.invalidLength
        }

        var salt = Data(count: saltLength)
        let status = salt.withUnsafeMutableBytes { buffer -> OSStatus in
            guard let baseAddress = buffer.baseAddress else { return errSecParam }
            return SecRandomCopyBytes(kSecRandomDefault, saltLength, baseAddress)
        }
        guard status == errSecSuccess else {
            throw PINError.keychainFailure(status)
        }

        try writeBlob(salt + Self.hash(salt: salt, pin: digits))
    }

    func verify(_ pin: String) -> Bool {
        guard let blob = readBlob(), blob.count > saltLength else {
            return false
        }

        let salt = blob.prefix(saltLength)
        let storedHash = blob.suffix(from: saltLength)
        let computedHash = Self.hash(
            salt: Data(salt),
            pin: pin.trimmingCharacters(in: .whitespaces)
        )
        return Data(storedHash) == computedHash
    }

    /// Destructive removal for tests and future parent re-auth recovery.
    func clear() {
        SecItemDelete(baseQuery() as CFDictionary)
    }

    /// Test-only hook used to confirm independent salts produce different blobs.
    #if DEBUG
    func debugStoredBlob() -> Data? {
        readBlob()
    }
    #endif

    private static func isASCIIDigits(_ value: String) -> Bool {
        value.unicodeScalars.allSatisfy { scalar in
            scalar.value >= 48 && scalar.value <= 57
        }
    }

    private static func hash(salt: Data, pin: String) -> Data {
        var input = salt
        input.append(Data(pin.utf8))
        return Data(SHA256.hash(data: input))
    }

    private func writeBlob(_ data: Data) throws {
        var query = baseQuery()
        SecItemDelete(query as CFDictionary)

        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw PINError.keychainFailure(status)
        }
    }

    private func readBlob() -> Data? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var output: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &output)
        guard status == errSecSuccess else {
            return nil
        }
        return output as? Data
    }

    private func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}
