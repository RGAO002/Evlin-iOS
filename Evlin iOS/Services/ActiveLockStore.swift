import Foundation
import FamilyControls
import ManagedSettings
import DeviceActivity

/// Single source of truth for active locks on this device. Every add/remove/sweep
/// triggers a full recompute of the union and writes to ManagedSettingsStore.
actor ActiveLockStore {
    static let shared = ActiveLockStore()

    private var locks: [UUID: ActiveLock] = [:]
    private let store = ManagedSettingsStore()
    private let storageKey = "evlin.activeLocks"
    private let defaults = UserDefaults(suiteName: "group.com.evlin.ios")

    init() {
        restore()
    }

    // MARK: - Public API

    func add(_ lock: ActiveLock) {
        locks[lock.id] = lock
        persist()
        recomputeAndApply()
    }

    func remove(commandID: UUID) {
        locks.removeValue(forKey: commandID)
        persist()
        recomputeAndApply()
    }

    func removeAll() {
        locks.removeAll()
        persist()
        recomputeAndApply()
    }

    /// Returns IDs of locks removed due to expiry.
    @discardableResult
    func sweepExpired(now: Date = Date()) -> [UUID] {
        let expired = locks.values
            .filter { ($0.expiresAt ?? .distantFuture) <= now }
            .map(\.id)
        guard !expired.isEmpty else { return [] }
        for id in expired { locks.removeValue(forKey: id) }
        persist()
        recomputeAndApply()
        return expired
    }

    /// Removes locks whose displayName or bundle IDs match the target.
    @discardableResult
    func removeMatching(_ target: CommandTarget) -> [UUID] {
        let matched = locks.values.filter { lock in
            if let bid = target.bundleID, lock.blockedBundleIDs.contains(bid) { return true }
            if let display = target.targetDisplay,
               lock.displayName.caseInsensitiveCompare(display) == .orderedSame { return true }
            if let list = target.listName,
               lock.displayName.caseInsensitiveCompare(list) == .orderedSame { return true }
            return false
        }.map(\.id)
        for id in matched { locks.removeValue(forKey: id) }
        if !matched.isEmpty {
            persist()
            recomputeAndApply()
        }
        return matched
    }

    func current() -> [ActiveLock] { Array(locks.values) }

    // MARK: - Core

    private func recomputeAndApply() {
        if locks.isEmpty {
            store.application.blockedApplications = nil
            store.shield.applications = nil
            store.shield.applicationCategories = nil
            return
        }

        let allBundleIDs = Set(locks.values.flatMap(\.blockedBundleIDs))
        let bundleApps = Set(allBundleIDs.map { Application(bundleIdentifier: $0) })
        store.application.blockedApplications = bundleApps.isEmpty ? nil : bundleApps

        let allAppTokens = Set(locks.values.flatMap(\.shieldAppTokens))
        store.shield.applications = allAppTokens.isEmpty ? nil : allAppTokens

        let allCategoryTokens = Set(locks.values.flatMap(\.shieldCategoryTokens))
        store.shield.applicationCategories = allCategoryTokens.isEmpty
            ? nil
            : .specific(allCategoryTokens)
    }

    private func persist() {
        guard let data = try? PropertyListEncoder().encode(locks) else { return }
        defaults?.set(data, forKey: storageKey)
    }

    private func restore() {
        guard let data = defaults?.data(forKey: storageKey),
              let decoded = try? PropertyListDecoder().decode([UUID: ActiveLock].self, from: data)
        else { return }
        locks = decoded
    }
}
