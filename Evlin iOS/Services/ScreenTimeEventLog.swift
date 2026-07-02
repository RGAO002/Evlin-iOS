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
    static let cap = 500
    static let suiteName = "group.com.evlin.ios"

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
    }
}
