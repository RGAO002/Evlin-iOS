import Foundation
import FamilyControls
import ManagedSettings
import DeviceActivity
import Combine
import UIKit

/// Central manager for FamilyControls authorization, app shielding, and polling.
class ScreenTimeManager: ObservableObject {
    static let shared = ScreenTimeManager()

    // MARK: - Published state

    @Published var isAuthorized: Bool = false
    @Published var isUnlocked: Bool = false
    @Published var selectedApps = FamilyActivitySelection()
    @Published var errorMessage: String?

    // MARK: - Private

    private let store = ManagedSettingsStore()
    private let activityCenter = DeviceActivityCenter()

    /// Shared UserDefaults for communicating with the DeviceActivityMonitor extension.
    private let sharedDefaults = UserDefaults(suiteName: "group.com.evlin.ios")

    private init() {
        isAuthorized = AuthorizationCenter.shared.authorizationStatus == .approved

        // Restore saved selection
        if let data = sharedDefaults?.data(forKey: "selectedApps"),
           let selection = try? PropertyListDecoder().decode(FamilyActivitySelection.self, from: data) {
            selectedApps = selection
        }
    }

    // MARK: - Authorization

    func requestAuthorization() async {
        do {
            try await AuthorizationCenter.shared.requestAuthorization(for: .individual)
            await MainActor.run {
                self.isAuthorized = true
                self.errorMessage = nil
                self.enableDeletionProtection()
            }
        } catch {
            await MainActor.run {
                self.errorMessage = "Authorization failed: \(error.localizedDescription)"
            }
        }
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
        enableDeletionProtection()
        Task {
            await ActiveLockStore.shared.removeAll()
            await MainActor.run {
                NotificationCenter.default.post(name: .evlinLockStateChanged, object: false)
            }
        }
    }

    /// Prevent Evlin from being deleted. This is intentionally separate from
    /// lock/unlock state so unlocking apps doesn't make Evlin removable.
    func enableDeletionProtection() {
        store.application.denyAppRemoval = true
        UserDefaults.standard.set(true, forKey: "evlin.deletionProtectionEnabled")
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
        if let data = try? PropertyListEncoder().encode(selectedApps) {
            sharedDefaults?.set(data, forKey: "selectedApps")
        }
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
