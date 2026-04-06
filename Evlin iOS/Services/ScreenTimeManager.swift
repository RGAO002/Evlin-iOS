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
            }
        } catch {
            await MainActor.run {
                self.errorMessage = "Authorization failed: \(error.localizedDescription)"
            }
        }
    }

    /// Best-effort jump into iOS Screen Time settings.
    /// Uses private Settings URL schemes first, then falls back to this app's settings page.
    @MainActor
    func openScreenTimeSettings() async {
        let candidates = [
            "App-prefs:root=SCREEN_TIME",
            "App-prefs:SCREEN_TIME",
            "prefs:root=SCREEN_TIME",
            "prefs:root=SCREEN_TIME&path=SCREEN_TIME_SUMMARY"
        ]

        for candidate in candidates {
            guard let url = URL(string: candidate) else { continue }
            if await open(url) {
                errorMessage = nil
                return
            }
        }

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
        print("[ScreenTime] shield applied: categories=.all(), apps=\(appTokens.count)")
    }

    /// Unshield (unlock) apps for the given duration.
    func unshieldApps(forMinutes minutes: Int) {
        store.clearAllSettings()
        isUnlocked = true
        scheduleRelock(afterMinutes: minutes)
    }

    /// Remove all shields.
    func clearAllShields() {
        store.clearAllSettings()
        isUnlocked = true
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
