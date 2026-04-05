import Foundation
import DeviceActivity
import ManagedSettings
import FamilyControls

/// Re-applies app shields when the unlock window expires.
class DeviceActivityMonitorExtension: DeviceActivityMonitor {

    private let store = ManagedSettingsStore()
    private let sharedDefaults = UserDefaults(suiteName: "group.com.evlin.ios")

    override func intervalDidEnd(for activity: DeviceActivityName) {
        super.intervalDidEnd(for: activity)

        // Re-apply shields from saved selection
        guard let data = sharedDefaults?.data(forKey: "selectedApps"),
              let selection = try? PropertyListDecoder().decode(FamilyActivitySelection.self, from: data)
        else {
            store.shield.applicationCategories = .all()
            return
        }

        let appTokens = selection.applicationTokens
        let categoryTokens = selection.categoryTokens

        if !appTokens.isEmpty {
            store.shield.applications = appTokens
        }
        if !categoryTokens.isEmpty {
            store.shield.applicationCategories = .specific(categoryTokens)
        }
    }
}
