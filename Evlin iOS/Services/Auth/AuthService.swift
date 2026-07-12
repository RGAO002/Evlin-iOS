import Foundation
import Observation

// NOTE (§15.7 PIN A / Task 11): the canonical `AuthAccountDTO` is declared ONCE,
// in `APIClient.swift` (Task 10 had to introduce it there because its
// `AuthResultDTO.account` + single-flight refresher consume it before this file
// landed). It lives in the SAME module, so this file references that EXACT type
// directly — declaring a second top-level `AuthAccountDTO` here would be an
// "Invalid redeclaration" compile error. Do NOT redeclare it.

/// Single source of truth for the parent's authenticated session. Holds the
/// session state derived from the Keychain and exposes sign-in entry points
/// that POST to the backend /auth/* routes. §6.1.
@MainActor
@Observable
final class AuthService {
    enum SessionState: Equatable {
        case unknown          // not yet checked
        case signedOut
        case signedIn(AuthAccountDTO)
    }

    private(set) var state: SessionState = .unknown
    private(set) var lastError: String?

    /// The canonical authed account (§15.7), or nil when not signed in.
    /// Feature code reads `auth.account?.familyID` / `.displayName` / `.needsFamily`.
    var account: AuthAccountDTO? {
        if case .signedIn(let acct) = state { return acct }
        return nil
    }

    /// True when a session blob is present in the Keychain. Used by the Plan 6
    /// DEBUG guard (§15.7). Presence-only check — does NOT validate the token.
    var hasStoredSession: Bool {
        KeychainStore.shared.load() != nil
    }

    private let api: APIClient
    private let terminalSessionTeardown: () -> Void

    init(
        api: APIClient,
        terminalSessionTeardown: (() -> Void)? = nil
    ) {
        self.api = api
        self.terminalSessionTeardown = terminalSessionTeardown ?? {
            AuthService.clearFamilyScopedLocalState()
        }
        // Listen for terminal refresh failure published by APIClient (§14.7).
        NotificationCenter.default.addObserver(
            forName: .evlinSessionSignedOut, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handleTerminalSessionSignOut()
            }
        }
    }

    private func handleTerminalSessionSignOut() {
        terminalSessionTeardown()
        state = .signedOut
    }

    /// Restore session from the Keychain at launch. Does not hit the network;
    /// the first authed call will refresh if the access token is stale.
    /// Rebuilds the full AuthAccountDTO (familyID/displayName) from the blob.
    func restore() {
        // One-shot migration: drop the legacy global evlin_chat_history key on
        // the first launch of this build. Never uploaded, never migrated.
        let legacyCleanedKey = "evlin.legacyChatHistoryDropped"
        if !UserDefaults.standard.bool(forKey: legacyCleanedKey) {
            UserDefaults.standard.removeObject(forKey: "evlin_chat_history")
            UserDefaults.standard.set(true, forKey: legacyCleanedKey)
        }
        if let stored = KeychainStore.shared.load(),
           let acct = Self.accountDTO(from: stored) {
            state = .signedIn(acct)
            // Persist account id so ChatViewModel can scope its store on init.
            UserDefaults.standard.set(acct.id.uuidString, forKey: "evlin.accountID")
            NotificationCenter.default.post(
                name: .evlinAccountSignedIn,
                object: nil,
                userInfo: ["account_id": acct.id.uuidString]
            )
        } else {
            state = .signedOut
        }
    }

    /// Rebuild the canonical (Codable) `AuthAccountDTO` from the persisted
    /// Keychain blob — no network. Returns nil if `accountID` isn't a UUID.
    /// (The blob stores the account's fields as strings; the DTO itself is the
    /// one `Codable` type from §15.7 PIN A, here built via its memberwise init.)
    private static func accountDTO(from stored: StoredTokens) -> AuthAccountDTO? {
        guard let uid = UUID(uuidString: stored.accountID) else { return nil }
        return AuthAccountDTO(
            id: uid,
            familyID: stored.familyID.flatMap(UUID.init(uuidString:)),
            displayName: stored.displayName,
            needsFamily: stored.needsFamily
        )
    }

    /// POST /auth/google with the provider id_token (and optional full name).
    func signInWithGoogle(idToken: String, fullName: String?) async {
        await postAuth(path: "/auth/google", body: [
            "id_token": idToken, "full_name": fullName as Any,
        ])
    }

    /// POST /auth/apple with the identity token + authorization code + nonce.
    func signInWithApple(identityToken: String, authorizationCode: String?,
                         fullName: String?, rawNonce: String) async {
        await postAuth(path: "/auth/apple", body: [
            "identity_token": identityToken,
            "authorization_code": authorizationCode as Any,
            "full_name": fullName as Any,
            "nonce": rawNonce,
        ])
    }

    func signOutLocally() {
        KeychainStore.shared.clear()
        DeviceIdentity.shared.clear()
        Self.clearFamilyScopedLocalState()
        state = .signedOut
        // Clear chat so account B never sees account A's messages.
        UserDefaults.standard.removeObject(forKey: "evlin_chat_history")
        NotificationCenter.default.post(name: .evlinClearChat, object: nil)
    }

    static func clearFamilyScopedLocalState(
        defaults: UserDefaults = .standard,
        appGroupDefaults: UserDefaults? = UserDefaults(
            suiteName: EarnedTimeStore.appGroupSuiteName
        ),
        clearOnboardingShell: Bool = true,
        teardownEarned: (() -> Void)? = nil
    ) {
        if let teardownEarned {
            teardownEarned()
        } else {
            EarnedBudgetArming.teardownFamilyIdentity(
                appGroupDefaults: appGroupDefaults
            )
        }
        appGroupDefaults?.removeObject(forKey: "evlin.childId")
        appGroupDefaults?.synchronize()
        var keys = [
            "evlin.accountID",
            "evlin.parentProfileID",
            "evlin.childProfileID",
            "evlin.familyID",
            DeviceIdentity.parentKey,
            DeviceIdentity.childKey,
            "evlin.childProfileName",
            "evlin.childBirthYear",
            "evlin.childGender",
            "evlin.protectionMode",
            APIClient.clientInstallIDKey,
        ]
        if clearOnboardingShell {
            keys.append(contentsOf: [
                "onboardingComplete",
                "appMode",
            ])
        }
        for key in keys {
            defaults.removeObject(forKey: key)
        }
        LocalAliasStore.shared.removeAllAliases()
        AppLimitRuleStore.shared.removeAll()
        EarnedTimeStore.shared.removeAll()
        APIClient.resetClientInstallID()
    }

    /// POST /auth/email {email, password, full_name?}. The backend create-or-
    /// authenticates on (provider=email, provider_sub=lowercased email) and
    /// returns the SAME session JSON as /auth/google, so the result feeds the
    /// SAME `postAuth` path (Keychain + state populated identically).
    func signInWithEmail(email: String, password: String,
                         fullName: String? = nil) async {
        await postAuth(path: "/auth/email", body: [
            "email": email,
            "password": password,
            "full_name": fullName as Any,
        ])
    }

    /// Single Device Mode (demo): create-or-auth the per-run demo parent account. Reuses the real
    /// `/auth/email` path; `SingleDeviceSession` mints a fresh email+password each run so a
    /// reset+rerun never collides with the prior account (and so `/family/pair` never 409s).
    func signInDemoAccount() async {
        await signInWithEmail(email: SingleDeviceSession.shared.demoEmail,
                              password: SingleDeviceSession.shared.demoPassword,
                              fullName: "Demo Parent")
    }

    private func postAuth(path: String, body: [String: Any]) async {
        lastError = nil
        let url = URL(string: "\(api.baseURL)\(path)")!
        var req = URLRequest(url: url)
        req.timeoutInterval = 15
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let cleaned = body.compactMapValues { value -> Any? in
            if value is NSNull { return nil }
            if let s = value as? String { return s }
            return value
        }
        req.httpBody = try? JSONSerialization.data(withJSONObject: cleaned)
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse else {
                lastError = "network_error"; return
            }
            guard http.statusCode == 200 else {
                // 401 user-cancel / invalid token; surface a non-fatal error.
                lastError = "auth_failed_\(http.statusCode)"; return
            }
            let result = try JSONDecoder().decode(AuthResultDTO.self, from: data)
            // §15.7 PIN A: `result.account` IS the canonical Codable AuthAccountDTO
            // (decoded directly, UUID-typed, `needsFamily` from INSIDE the account).
            let acct = result.account
            let previousAccountID = KeychainStore.shared.load()?.accountID
            if acct.needsFamily || previousAccountID.map({ $0 != acct.id.uuidString }) ?? true {
                DeviceIdentity.shared.clear()
                Self.clearFamilyScopedLocalState(clearOnboardingShell: false)
            }
            // Persist the WHOLE account (§15.7): familyID + displayName included.
            try KeychainStore.shared.save(StoredTokens(
                accessToken: result.access_token,
                refreshToken: result.refresh_token,
                accountID: acct.id.uuidString,
                familyID: acct.familyID?.uuidString,
                displayName: acct.displayName,
                needsFamily: acct.needsFamily
            ))
            state = .signedIn(acct)
            // Persist account id so ChatViewModel can scope its store on init/re-init.
            UserDefaults.standard.set(acct.id.uuidString, forKey: "evlin.accountID")
            NotificationCenter.default.post(
                name: .evlinAccountSignedIn,
                object: nil,
                userInfo: ["account_id": acct.id.uuidString]
            )
        } catch {
            lastError = "network_error: \(error.localizedDescription)"
        }
    }
}
