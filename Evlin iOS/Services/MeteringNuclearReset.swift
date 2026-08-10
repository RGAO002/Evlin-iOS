import Foundation
import DeviceActivity
import ManagedSettings

/// Shared "nuclear reset" of on-device Screen Time enforcement state.
///
/// Frees Apple's DeviceActivity capacity (the ~20-activity hard limit) by
/// stopping EVERY scheduled activity, then drops all ManagedSettings policy and
/// wipes ActiveLockStore's records + persisted App Group JSON. This is the only
/// reliable way to recover a device whose metering has churned itself into
/// `coverageExhausted`: a targeted "repair" that stops only stale activities
/// cannot free capacity that retired-but-still-registered activities are
/// holding.
///
/// Callers own re-arming — the next foreground recovery pass re-plans and arms a
/// fresh route from the shared configuration. Deletion-protection restore and
/// any UI flags are the caller's responsibility (see `HomeSettingsSheet`).
enum MeteringNuclearReset {
    /// - Parameter includeMeteringStore: when true, ALSO purge the v2 metering
    ///   epoch store (`DeviceEpochStore`). The lock-state reset below stops
    ///   Apple's activities and clears shields, but it does NOT touch the
    ///   metering brain — a device churned into `coverageExhausted` with a
    ///   paused epoch stays wedged until that persisted state is wiped. The
    ///   P-end "Nuclear Reset (lock state)" leaves this false (lock-only); the
    ///   K-device button passes true so a fresh route can arm.
    @discardableResult
    static func run(includeMeteringStore: Bool = false) async -> String {
        // Audited adapters rather than raw DeviceActivityCenter: both calls
        // below are synchronous XPC, and this runs from a user-facing settings
        // button, not a debug screen.
        let auditedCenter = SystemMeteringDeviceActivityCenter()
        let auditedScheduler = DeviceActivityCenterScheduler()
        // A3: a nuclear reset destroys every activity and (optionally) the
        // whole metering store. Anything that happens afterwards has to be
        // readable in the light of "someone nuked the device at this instant",
        // so the intent is recorded BEFORE the destruction, not only after.
        MeteringFlightRecorder.emit(
            kind: .meteringRepair,
            site: "nuke.run",
            verdict: "started",
            detail: MeteringFlightRecorder.detail([
                ("includeStore", String(includeMeteringStore)),
                ("activities", String(auditedCenter.activities.count)),
            ])
        )
        // 1. Stop every scheduled DeviceActivity callback FIRST. If we don't, a
        //    pending intervalDidEnd could fire mid-reset and write its own
        //    recompute back on top of us. This is also what releases Apple's
        //    activity capacity so a fresh route can arm.
        auditedScheduler.stopMonitoring()

        // 2. Drop every ManagedSettings policy this app has set. Broader than
        //    clearLockRestrictions() — also clears categories, webDomains,
        //    application.denyAppRemoval, etc. Callers that need deletion
        //    protection must restore it (clearAllSettings drops denyAppRemoval).
        ManagedSettingsStore().clearAllSettings()

        // 3. Wipe ActiveLockStore's record dicts (belt and suspenders after 2).
        let shields = await ActiveLockStore.shared.unshieldAll()
        let blocks = await ActiveLockStore.shared.unblockAll()

        // 4. Scrub every evlin.* shield/block/diagnostic key in the App Group so
        //    stale persisted JSON can't mislead future debugging.
        if let groupDefaults = UserDefaults(suiteName: "group.com.evlin.ios") {
            _ = ActiveLockPersistenceLock.shared.withLock {
                for key in [
                    "evlin.shieldRecords",
                    "evlin.blockRecords",
                    "evlin.lastScheduleResult",
                    "evlin.lastIntervalDidEnd",
                    "evlin.lastRecompute",
                ] {
                    groupDefaults.removeObject(forKey: key)
                }
            }
        }

        // 5. Optionally purge the v2 metering epoch store so a device wedged
        //    into coverageExhausted / a paused epoch starts fresh. Steps 1-4
        //    (esp. stopMonitoring) already ran, so no in-flight callback
        //    transaction will rewrite the file after we remove it.
        var meteringNote = ""
        var purgeVerdict = "skipped"
        if includeMeteringStore {
            do {
                try DeviceEpochStore.shared.purgePersistedState()
                meteringNote = " Metering store purged."
                purgeVerdict = "purged"
            } catch {
                meteringNote = " Metering store purge FAILED: \(error)."
                purgeVerdict = "purge_failed"
                MeteringFlightRecorder.emitError(site: "nuke.purge", error: error)
            }
        }

        MeteringFlightRecorder.emit(
            kind: .meteringRepair,
            site: "nuke.run",
            verdict: "done_\(purgeVerdict)",
            detail: MeteringFlightRecorder.detail([
                ("shields", String(shields.count)),
                ("blocks", String(blocks.count)),
            ]),
            nums: ScreenTimeEvent.Nums(count: shields.count + blocks.count)
        )
        return "Nuclear reset done — stopped all activities, cleared "
            + "\(shields.count) shield(s) + \(blocks.count) block(s).\(meteringNote) "
            + "Keep Evlin foreground so metering re-arms."
    }
}
