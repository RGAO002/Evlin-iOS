import CryptoKit
import Foundation
import Security

/// Evlin-managed edit-gate PIN. The raw PIN is never persisted — only
/// `salt || sha256(salt || pinBytes)` is stored.
///
/// Storage lives in the **App Group container** (`group.com.evlin.ios`), not the
/// keychain. Rationale: the keychain's access group is derived from the signing
/// team prefix (`$(AppIdentifierPrefix)`), so during development — simulator
/// ad-hoc signing, or a team-id flip — every build reads a *different* keychain
/// partition and the previously-set PIN looks gone, forcing a re-create on each
/// recompile. The App Group container is keyed by group id, so it survives
/// rebuilds and reinstalls regardless of signing. A deliberate `clear()` (called
/// by the kid-side Sign out teardown) still wipes it, so signing out and coming
/// back correctly requires setting the PIN again.
///
/// Security trade-off vs keychain: the salted hash now sits in the App Group
/// (readable by the app's own extensions; included in device backups) rather
/// than encrypted keychain storage. This is acceptable for a *local* edit-gate
/// whose realistic bypass — a factory reset — is already easier than extracting
/// and brute-forcing the salted digest. It is NOT a credential store.
nonisolated final class EvlinPINStore {
    static let shared = EvlinPINStore(account: "evlin.editGatePIN")

    enum PINError: Error, Equatable {
        case invalidLength
        case keychainFailure(OSStatus)
    }

    static let minLength = 4
    static let maxLength = 8

    private static let appGroup = "group.com.evlin.ios"
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

        writeBlob(salt + Self.hash(salt: salt, pin: digits))
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

    /// Destructive removal for the Sign out teardown, tests, and future
    /// parent re-auth recovery.
    func clear() {
        defaults.removeObject(forKey: storageKey)
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

    // MARK: - Persistence (App Group container)

    /// Shared App Group defaults. Falls back to `.standard` if the group suite
    /// is unavailable (e.g. a test host without the entitlement) — still keyed
    /// per account, so behaviour and isolation are unchanged.
    private var defaults: UserDefaults {
        UserDefaults(suiteName: Self.appGroup) ?? .standard
    }

    private var storageKey: String { "evlin.pinblob.\(account)" }

    private func writeBlob(_ data: Data) {
        defaults.set(data, forKey: storageKey)
    }

    private func readBlob() -> Data? {
        defaults.data(forKey: storageKey)
    }
}
