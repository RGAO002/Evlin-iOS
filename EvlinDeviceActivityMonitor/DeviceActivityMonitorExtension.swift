import Foundation
import DeviceActivity
import ManagedSettings

class DeviceActivityMonitorExtension: DeviceActivityMonitor {
    private let storageKey = "evlin.activeLocks"
    private let defaults = UserDefaults(suiteName: "group.com.evlin.ios")
    private let store = ManagedSettingsStore()

    override func intervalDidEnd(for activity: DeviceActivityName) {
        super.intervalDidEnd(for: activity)

        // Name format: "evlin.lock.<uuid>" — produced by ActionExecutor.scheduleRelock
        let rawName = activity.rawValue
        guard rawName.hasPrefix("evlin.lock.") else { return }
        let suffix = String(rawName.dropFirst("evlin.lock.".count))
        guard let cmdID = UUID(uuidString: suffix) else { return }

        removeLockAndRecompute(commandID: cmdID)
    }

    private func removeLockAndRecompute(commandID: UUID) {
        guard let data = defaults?.data(forKey: storageKey),
              var locks = try? PropertyListDecoder().decode([UUID: ActiveLock].self, from: data)
        else { return }

        locks.removeValue(forKey: commandID)

        // Persist the updated dictionary
        if let updated = try? PropertyListEncoder().encode(locks) {
            defaults?.set(updated, forKey: storageKey)
        }

        // Recompute union and apply — same logic as ActiveLockStore.recomputeAndApply()
        if locks.isEmpty {
            store.application.blockedApplications = nil
            store.shield.applications = nil
            store.shield.applicationCategories = nil
            return
        }

        let allBundleIDs = Set(locks.values.flatMap(\.blockedBundleIDs))
        let bundleApps = Set(allBundleIDs.map { ManagedSettings.Application(bundleIdentifier: $0) })
        store.application.blockedApplications = bundleApps.isEmpty ? nil : bundleApps

        let allAppTokens = Set(locks.values.flatMap(\.shieldAppTokens))
        store.shield.applications = allAppTokens.isEmpty ? nil : allAppTokens

        let allCategoryTokens = Set(locks.values.flatMap(\.shieldCategoryTokens))
        store.shield.applicationCategories = allCategoryTokens.isEmpty
            ? nil : .specific(allCategoryTokens)
    }
}
