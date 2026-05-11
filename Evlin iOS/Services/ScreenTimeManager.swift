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

    // MARK: - Published state

    @Published var isAuthorized: Bool = false
    @Published var isUnlocked: Bool = false
    /// `includeEntireCategory: true` is what makes the picker record a category-row tap as
    /// `categoryTokens` instead of expanding into individual app tokens. Without it,
    /// `shieldApps()` never sees any category tokens and the "lock by category" path is dead.
    @Published var selectedApps = FamilyActivitySelection(includeEntireCategory: true)
    @Published var errorMessage: String?
    /// Mirrors `ManagedSettingsStore.application.denyAppRemoval` intent; persists across launches.
    @Published private(set) var deletionProtectionEnabled: Bool

    // MARK: - Private

    private let store = ManagedSettingsStore()
    private let activityCenter = DeviceActivityCenter()

    /// Shared UserDefaults for communicating with the DeviceActivityMonitor extension.
    private let sharedDefaults = UserDefaults(suiteName: "group.com.evlin.ios")

    private init() {
        isAuthorized = AuthorizationCenter.shared.authorizationStatus == .approved
        let persistedDeletion = UserDefaults.standard.object(forKey: Self.deletionProtectionDefaultsKey) as? Bool ?? true
        deletionProtectionEnabled = persistedDeletion
        store.application.denyAppRemoval = persistedDeletion

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

    // MARK: - App Shielding

    /// Shield (lock) the selected apps.
    func shieldApps() {
        let appTokens = selectedApps.applicationTokens
        let categoryTokens = selectedApps.categoryTokens

        if !appTokens.isEmpty {
            store.shield.applications = appTokens
        }
        if !categoryTokens.isEmpty {
            store.shield.applicationCategories = .specific(categoryTokens)
        }

        isUnlocked = false
        saveSelection()
        NotificationCenter.default.post(name: .evlinLockStateChanged, object: true)
    }

    /// Shield ALL apps (full device lock).
    func shieldAllApps() {
        print("[ScreenTime] shieldAllApps called, isAuthorized=\(isAuthorized)")
        store.shield.applicationCategories = .all()
        store.shield.webDomainCategories = .all()
        // Also shield individually selected apps if any
        let appTokens = selectedApps.applicationTokens
        if !appTokens.isEmpty {
            store.shield.applications = appTokens
        }
        isUnlocked = false
        NotificationCenter.default.post(name: .evlinLockStateChanged, object: true)
        print("[ScreenTime] shield applied: categories=.all(), apps=\(appTokens.count)")
    }

    /// Unshield (unlock) apps for the given duration.
    func unshieldApps(forMinutes minutes: Int) {
        clearLockRestrictions()
        isUnlocked = true
        NotificationCenter.default.post(name: .evlinLockStateChanged, object: false)
        scheduleRelock(afterMinutes: minutes)
    }

    /// Remove all shields.
    func clearAllShields() {
        clearLockRestrictions()
        isUnlocked = true
        syncDeletionProtectionToManagedSettings()
        Task {
            // Clear both shield + block records (spec §3 — two independent stores).
            _ = await ActiveLockStore.shared.unshieldAll()
            _ = await ActiveLockStore.shared.unblockAll()
            await MainActor.run {
                NotificationCenter.default.post(name: .evlinLockStateChanged, object: false)
            }
        }
    }

    /// User preference for `ManagedSettingsStore.application.denyAppRemoval`. Default ON.
    func setDeletionProtectionEnabled(_ enabled: Bool) {
        guard deletionProtectionEnabled != enabled else {
            syncDeletionProtectionToManagedSettings()
            return
        }
        deletionProtectionEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: Self.deletionProtectionDefaultsKey)
        store.application.denyAppRemoval = enabled
    }

    /// Re-apply persisted preference to Managed Settings (called on launch, foreground, after unlock-all).
    func syncDeletionProtectionToManagedSettings() {
        let persisted = UserDefaults.standard.object(forKey: Self.deletionProtectionDefaultsKey) as? Bool ?? true
        if persisted != deletionProtectionEnabled {
            deletionProtectionEnabled = persisted
        }
        store.application.denyAppRemoval = persisted
    }

    /// Backward-compatible name — applies current preference only.
    func enableDeletionProtection() {
        syncDeletionProtectionToManagedSettings()
    }

    /// Clear only lock-related settings. Do not call `clearAllSettings()` here:
    /// it also clears `application.denyAppRemoval`, making Evlin deletable.
    private func clearLockRestrictions() {
        store.application.blockedApplications = nil
        store.shield.applications = nil
        store.shield.applicationCategories = nil
        store.shield.webDomainCategories = nil
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

    // MARK: - Auto-Relock via DeviceActivity

    private func scheduleRelock(afterMinutes minutes: Int) {
        let calendar = Calendar.current
        let now = Date()
        guard let endDate = calendar.date(byAdding: .minute, value: minutes, to: now) else { return }

        let startComponents = calendar.dateComponents([.hour, .minute, .second], from: now)
        let endComponents = calendar.dateComponents([.hour, .minute, .second], from: endDate)

        let schedule = DeviceActivitySchedule(
            intervalStart: startComponents,
            intervalEnd: endComponents,
            repeats: false
        )

        let activityName = DeviceActivityName("evlin.ios.unlock")
        do {
            try activityCenter.startMonitoring(activityName, during: schedule)
        } catch {
            print("[ScreenTime] Failed to schedule relock: \(error)")
        }
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
