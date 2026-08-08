import Foundation
import FamilyControls
import ManagedSettings
import DeviceActivity
import Combine
import UIKit

/// Central manager for FamilyControls authorization, app shielding, and polling.
class ScreenTimeManager: ObservableObject {
    static let shared = ScreenTimeManager()

    static let deletionProtectionDefaultsKey = "evlin.deletionProtectionEnabled"

    enum DeletionProtectionApplyPlan: Equatable {
        case setDenyAppRemoval(Bool?)
        case clearAllSettingsThenReapplyActiveLocks
    }

    static func deletionRestrictionValue(for enabled: Bool) -> Bool? {
        enabled ? true : nil
    }

    static func deletionProtectionApplyPlan(for enabled: Bool) -> DeletionProtectionApplyPlan {
        enabled ? .setDenyAppRemoval(true) : .clearAllSettingsThenReapplyActiveLocks
    }

    // MARK: - Published state

    @Published var isAuthorized: Bool = false
    @Published var isUnlocked: Bool = false
    /// This legacy store keeps `includeEntireCategory: true` only for its OWN older capture
    /// path. It is NOT globally required for category locking. Verified on-device: the App
    /// Controls v2 combined picker uses `includeEntireCategory: false` and category locking
    /// still works (category-only selection → applicationTokens empty, categoryTokens ≥ 1, and
    /// the category shield applies). With `false`, a category-row tap is recorded as a
    /// `categoryToken` (not expanded into app tokens), keeping app vs category buckets disjoint.
    @Published var selectedApps = FamilyActivitySelection(includeEntireCategory: true)
    @Published var errorMessage: String?
    /// Mirrors `ManagedSettingsStore.application.denyAppRemoval` intent; persists across launches.
    @Published private(set) var deletionProtectionEnabled: Bool

    // MARK: - Private

    private let store = ManagedSettingsStore()

    /// Shared UserDefaults for communicating with the DeviceActivityMonitor extension.
    private let sharedDefaults = UserDefaults(suiteName: "group.com.evlin.ios")

    private init() {
        isAuthorized = AuthorizationCenter.shared.authorizationStatus == .approved
        // Default OFF. Only the child onboarding `DeletionProtectionStep` explicitly
        // turns it on for the child's device — a parent device must never protect
        // its own apps from deletion by default.
        let persistedDeletion = UserDefaults.standard.object(forKey: Self.deletionProtectionDefaultsKey) as? Bool ?? false
        deletionProtectionEnabled = persistedDeletion
        applyDeletionProtectionToManagedSettings(persistedDeletion)

        // Restore saved selection. Older builds persisted with `includeEntireCategory: false`,
        // so when we hydrate we copy tokens into a fresh selection that has the flag set —
        // ensures subsequent picker presentations keep recording category rows as category tokens.
        if let data = sharedDefaults?.data(forKey: "selectedApps"),
           let restored = try? PropertyListDecoder().decode(FamilyActivitySelection.self, from: data) {
            var merged = FamilyActivitySelection(includeEntireCategory: true)
            merged.applicationTokens = restored.applicationTokens
            merged.categoryTokens = restored.categoryTokens
            merged.webDomainTokens = restored.webDomainTokens
            // `applications` / `categories` are get-only — cannot restore metadata after plist decode.
            // `ManagedSelectionAliasSync` uses a persisted label snapshot instead (see ManagedSelectionAliasSync).
            selectedApps = merged
            ManagedSelectionAliasSync.syncAll(from: selectedApps)
        }

        NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.refreshAuthorizationStatus()
            self?.syncDeletionProtectionToManagedSettings()
        }
    }

    // MARK: - Authorization

    /// Re-read FamilyControls approval (e.g. after returning from Settings).
    func refreshAuthorizationStatus() {
        isAuthorized = AuthorizationCenter.shared.authorizationStatus == .approved
    }

    /// Uses `evlin.protectionMode` (`std` → `.individual`, `max` → `.child`) so demo / settings
    /// skips still match onboarding. Notifies backend for max mode when a child UUID exists.
    func requestAuthorization() async {
        await requestScreenTimeAuthorization()
    }

    func requestScreenTimeAuthorization() async {
        let mode = UserDefaults.standard.string(forKey: "evlin.protectionMode") ?? "std"
        let memberType: FamilyControlsMember = (mode == "max") ? .child : .individual
        do {
            try await AuthorizationCenter.shared.requestAuthorization(for: memberType)
            await MainActor.run {
                self.isAuthorized = true
                self.errorMessage = nil
                self.syncDeletionProtectionToManagedSettings()
            }
            if mode == "max",
               let raw = UserDefaults.standard.string(forKey: "evlin.childDeviceID"),
               let cid = UUID(uuidString: raw) {
                await postAuthGrantedToBackend(childDeviceID: cid)
            }
        } catch {
            await MainActor.run {
                let prefix = mode == "max"
                    ? "Maximum mode needs the Child Apple ID on this phone. "
                    : ""
                self.errorMessage = prefix + "\(error.localizedDescription)"
            }
        }
    }

    private func postAuthGrantedToBackend(childDeviceID: UUID) async {
        let base = APIClient().baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: "\(base)/family/auth-status/grant") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        guard let body = try? JSONSerialization.data(withJSONObject: [
            "child_device_id": childDeviceID.uuidString,
        ]) else { return }
        req.httpBody = body
        _ = try? await URLSession.shared.data(for: req)
    }

    /// Best-effort jump into iOS Settings. Prefers Screen Time deep-links, but
    /// iOS 17+ silently rejects most private sub-paths, so we also try a bare
    /// Settings-root URL, and finally fall back to this app's settings page.
    /// The onboarding UI assumes users may land anywhere in Settings and
    /// provides clear navigation instructions.
    @MainActor
    func openScreenTimeSettings() async {
        let candidates = [
            // Specific Screen Time deep-links (work on older iOS, often ignored on 17+)
            "App-prefs:root=SCREEN_TIME",
            "App-prefs:SCREEN_TIME",
            "prefs:root=SCREEN_TIME",
            // Bare Settings root (more reliable than app-specific pane)
            "App-Prefs:",
            "prefs:root="
        ]

        for candidate in candidates {
            guard let url = URL(string: candidate) else { continue }
            if await open(url) {
                errorMessage = nil
                return
            }
        }

        // Last resort — this lands on Evlin's own Settings pane, not the root.
        if let fallback = URL(string: UIApplication.openSettingsURLString) {
            let didOpenFallback = await open(fallback)
            if !didOpenFallback {
                errorMessage = "Unable to open Settings on this device."
            }
        } else {
            errorMessage = "Unable to build Settings URL."
        }
    }

    /// User preference for `ManagedSettingsStore.application.denyAppRemoval`. Default OFF
    /// (parent devices stay unprotected); the child onboarding step explicitly enables it.
    func setDeletionProtectionEnabled(_ enabled: Bool) {
        guard deletionProtectionEnabled != enabled else {
            applyDeletionProtectionToManagedSettings(enabled)
            return
        }
        deletionProtectionEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: Self.deletionProtectionDefaultsKey)
        applyDeletionProtectionToManagedSettings(enabled)
    }

    /// Re-apply persisted preference to Managed Settings (called on launch, foreground, after unlock-all).
    func syncDeletionProtectionToManagedSettings() {
        let persisted = UserDefaults.standard.object(forKey: Self.deletionProtectionDefaultsKey) as? Bool ?? false
        if persisted != deletionProtectionEnabled {
            deletionProtectionEnabled = persisted
        }
        applyDeletionProtectionToManagedSettings(persisted)
    }

    /// Backward-compatible name — applies current preference only.
    func enableDeletionProtection() {
        syncDeletionProtectionToManagedSettings()
    }

    private func applyDeletionProtectionToManagedSettings(_ enabled: Bool) {
        switch Self.deletionProtectionApplyPlan(for: enabled) {
        case .setDenyAppRemoval(let value):
            store.application.denyAppRemoval = value
        case .clearAllSettingsThenReapplyActiveLocks:
            store.application.denyAppRemoval = nil
            ManagedSettingsStore().clearAllSettings()
            Task {
                await ActiveLockStore.shared.reapplyCurrentRestrictions()
            }
        }
    }

    /// Drop the FamilyControls selection — the picked application / category /
    /// web-domain tokens — from memory AND the App Group. Used by account
    /// deletion and identity teardown so a NEW account can never inherit the
    /// previous family's App Controls picks. Tokens are opaque and scoped to
    /// the family that picked them; carrying them across identities is a
    /// privacy leak, not a convenience.
    func clearSelectionForIdentityTeardown() {
        selectedApps = FamilyActivitySelection(includeEntireCategory: true)
        sharedDefaults?.removeObject(forKey: "selectedApps")
        sharedDefaults?.synchronize()
    }

    /// Save the selected apps to shared UserDefaults so the Monitor extension can read them.
    func saveSelection() {
        // Persist semantic + picker display-string aliases (`LocalAliasStore`) from the
        // current Managed Apps selection; distinct from plist `selectedApps` payload.
        ManagedSelectionAliasSync.syncAll(from: selectedApps)
        if let data = try? PropertyListEncoder().encode(selectedApps) {
            sharedDefaults?.set(data, forKey: "selectedApps")
        }
        objectWillChange.send()
    }

    @MainActor
    private func open(_ url: URL) async -> Bool {
        await withCheckedContinuation { continuation in
            UIApplication.shared.open(url, options: [:]) { success in
                continuation.resume(returning: success)
            }
        }
    }
}

extension DeviceActivityName {
    static let evlinUnlock = Self("evlin.ios.unlock")
}
