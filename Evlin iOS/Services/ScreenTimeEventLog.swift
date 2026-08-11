import Foundation
import os

/// Emits `ScreenTimeEvent`s to (1) os_log for live Xcode/Console viewing and
/// (2) a capped JSONL ring buffer in App-Group UserDefaults for on-device
/// reading (see `ScreenTimeEventLogView`). Local only — no network here.
///
/// Membership: this file MUST be in BOTH the `Evlin iOS` and
/// `EvlinDeviceActivityMonitor` targets.
enum ScreenTimeEventLog {

    static let key = "evlin.screentime.events"
    static let extensionBreadcrumbKey = "evlin.screentime.extensionBreadcrumb"
    /// Callback arrival bypasses this ring so the extension can persist the
    /// sample before paying the cost of durable diagnostics.
    static let cap = 2000
    static let suiteName = "group.com.evlin.ios"

    /// A second ring holding only the events worth having AFTER something went
    /// wrong, so routine traffic cannot evict the failure that explains it.
    ///
    /// The main ring is FIFO with a 2000 cap. That makes an error and a
    /// heartbeat equally disposable: once the device carries on normally for
    /// 2000 events, the scene that would have explained the failure is gone.
    /// A whole day of debugging on 2026-08-08 came down to reading a crash log
    /// off the device by hand because the recorder had nothing left.
    static let preservedKey = "evlin.screentime.preserved"
    /// Small on purpose. These kinds are rare — at most a handful a day — so a
    /// few hundred slots is weeks of failures, and it stays cheap to re-scan.
    static let preservedCap = 300

    /// Kinds that survive rollover of the main ring. All are low-volume and
    /// high-signal: the previously-silent `catch` conversions, terminal work
    /// failures, drops, the midnight rollover (rare and historically the most
    /// fragile step), and operator repairs. The high-volume progress kinds —
    /// callbacks, samples, guards, watchdog heartbeats — are deliberately NOT
    /// here; they are what does the evicting.
    static let preservedKinds: Set<ScreenTimeEvent.Kind> = [
        .meteringError, .meteringWork, .drop, .meteringDay, .meteringRepair, .reset
    ]

    private static let logger = Logger(subsystem: "com.evlin.screentime", category: "event")
    private static var shared: UserDefaults? { UserDefaults(suiteName: suiteName) }

    static func emit(_ event: ScreenTimeEvent) {
        guard let d = shared else { return }
        emit(event, into: d)
    }

    static func emit(_ event: ScreenTimeEvent, into defaults: UserDefaults) {
        let line = event.jsonLine()
        // (1) os_log — filter in Console/Xcode by subsystem com.evlin.screentime
        logger.log("\(line, privacy: .public)")
        // (2) ring buffer
        var log = defaults.stringArray(forKey: key) ?? []
        log.append(line)
        if log.count > cap {
            log = Array(log.suffix(cap))
        }
        defaults.set(log, forKey: key)
        // (3) failure ring — same line, so the uploader's deterministic
        // `client_event_id` hash makes a duplicate upload idempotent rather
        // than a second event.
        guard preservedKinds.contains(event.kind) else { return }
        var preserved = defaults.stringArray(forKey: preservedKey) ?? []
        preserved.append(line)
        if preserved.count > preservedCap {
            preserved = Array(preserved.suffix(preservedCap))
        }
        defaults.set(preserved, forKey: preservedKey)
    }

    /// Failure lines still on the device, oldest → newest.
    static func preservedLines(from defaults: UserDefaults) -> [String] {
        defaults.stringArray(forKey: preservedKey) ?? []
    }

    static func preservedLines() -> [String] {
        guard let d = shared else { return [] }
        return preservedLines(from: d)
    }

    /// Records callback arrival without loading or rewriting the durable ring.
    /// This is intentionally a single-slot breadcrumb: the callback verdict and
    /// sample remain durable ring events after the epoch transaction completes.
    static func emitExtensionBreadcrumb(_ event: ScreenTimeEvent) {
        guard let d = shared else { return }
        emitExtensionBreadcrumb(event, into: d)
    }

    static func emitExtensionBreadcrumb(
        _ event: ScreenTimeEvent,
        into defaults: UserDefaults
    ) {
        let line = event.jsonLine()
        logger.log("\(line, privacy: .public)")
        defaults.set(line, forKey: extensionBreadcrumbKey)
    }

    static func read() -> [ScreenTimeEvent] {
        guard let d = shared else { return [] }
        return read(from: d)
    }

    static func read(from defaults: UserDefaults) -> [ScreenTimeEvent] {
        (defaults.stringArray(forKey: key) ?? []).compactMap(ScreenTimeEvent.from(jsonLine:))
    }

    /// Raw JSONL lines (oldest → newest). The A1 uploader hashes these for
    /// deterministic client_event_ids, so it needs the exact stored strings.
    static func readLines() -> [String] {
        guard let d = shared else { return [] }
        return readLines(from: d)
    }

    static func readLines(from defaults: UserDefaults) -> [String] {
        defaults.stringArray(forKey: key) ?? []
    }

    static func clear() {
        guard let d = shared else { return }
        clear(in: d)
    }

    static func clear(in defaults: UserDefaults) {
        defaults.removeObject(forKey: key)
        defaults.removeObject(forKey: preservedKey)
    }
}
