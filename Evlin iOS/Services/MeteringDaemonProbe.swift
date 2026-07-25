import DeviceActivity
import Foundation

/// The result of comparing what Apple's DeviceActivity daemon actually holds
/// for one activity against what the store expects it to hold.
///
/// `DatedRouteInstaller.daemonMatches` used to answer this with a single
/// `Bool`, which is why "coverage flipped to exhausted" was undiagnosable: the
/// store could not say WHICH of the four comparisons failed. Each comparison is
/// now reported separately and named in the flight-recorder event.
nonisolated struct MeteringDaemonProbeResult: Equatable, Sendable {
    /// The activity is registered with the daemon at all.
    var registered: Bool
    /// Interval start/end/repeats/warningTime are exactly equal.
    var scheduleMatches: Bool
    /// The daemon holds exactly the expected set of event names.
    var eventKeysMatch: Bool
    /// Every held event's selection + threshold + `includesPastActivity` match.
    var payloadMatches: Bool
    var daemonEventCount: Int
    var expectedEventCount: Int
    /// Total activities the daemon holds — the ~20 hard limit lives here.
    var daemonActivityCount: Int

    var isHealthy: Bool {
        registered && scheduleMatches && eventKeysMatch && payloadMatches
    }

    /// The FIRST failing comparison, in dependency order. `nil` when healthy.
    /// This is the single most valuable field in a coverage event: a missing
    /// registration and a drifted event payload need opposite repairs.
    var failure: String? {
        if !registered { return "registration" }
        if !scheduleMatches { return "schedule" }
        if !eventKeysMatch { return "event_set" }
        if !payloadMatches { return "payload" }
        return nil
    }

    /// Compact `k=v` summary for the event detail / debug report.
    var summary: String {
        guard registered else {
            return "reg=NO activities=\(daemonActivityCount)"
        }
        return [
            "reg=yes",
            "events=\(daemonEventCount)/\(expectedEventCount)",
            "keys=\(eventKeysMatch ? "ok" : "DIFF")",
            "sched=\(scheduleMatches ? "ok" : "DIFF")",
            "payload=\(payloadMatches ? "ok" : "DIFF")",
        ].joined(separator: " ")
    }
}

/// Shared read-only probe of the DeviceActivity daemon.
///
/// Extracted so the installer's coverage refresh, the debug re-kick report and
/// the A3 watchdog all compare the SAME way — three near-identical copies of
/// this comparison is how they drifted apart in the first place.
///
/// Membership: this file MUST be in BOTH the `Evlin iOS` and
/// `EvlinDeviceActivityMonitor` targets (`DatedRouteInstaller` uses it).
nonisolated enum MeteringDaemonProbe {

    static func probe(
        center: any MeteringDeviceActivityCenter,
        activity: DeviceActivityName,
        expectedSchedule: DeviceActivitySchedule,
        expectedEvents: [DeviceActivityEvent.Name: DeviceActivityEvent]
    ) -> MeteringDaemonProbeResult {
        let activities = center.activities
        guard activities.contains(activity) else {
            return MeteringDaemonProbeResult(
                registered: false,
                scheduleMatches: false,
                eventKeysMatch: false,
                payloadMatches: false,
                daemonEventCount: 0,
                expectedEventCount: expectedEvents.count,
                daemonActivityCount: activities.count
            )
        }
        let heldEvents = center.events(for: activity)
        let scheduleMatches = center.schedule(for: activity).map {
            exactSchedule($0, expectedSchedule)
        } ?? false
        let keysMatch = heldEvents.keys == expectedEvents.keys
        let payloadMatches = keysMatch && heldEvents.allSatisfy { name, event in
            guard let expected = expectedEvents[name] else { return false }
            return exactEvent(event, expected)
        }
        return MeteringDaemonProbeResult(
            registered: true,
            scheduleMatches: scheduleMatches,
            eventKeysMatch: keysMatch,
            payloadMatches: payloadMatches,
            daemonEventCount: heldEvents.count,
            expectedEventCount: expectedEvents.count,
            daemonActivityCount: activities.count
        )
    }

    static func exactSchedule(
        _ lhs: DeviceActivitySchedule,
        _ rhs: DeviceActivitySchedule
    ) -> Bool {
        lhs.intervalStart == rhs.intervalStart
            && lhs.intervalEnd == rhs.intervalEnd
            && lhs.repeats == rhs.repeats
            && lhs.warningTime == rhs.warningTime
    }

    static func exactEvent(
        _ lhs: DeviceActivityEvent,
        _ rhs: DeviceActivityEvent
    ) -> Bool {
        lhs.applications == rhs.applications
            && lhs.categories == rhs.categories
            && lhs.webDomains == rhs.webDomains
            && lhs.threshold == rhs.threshold
            && lhs.includesPastActivity == rhs.includesPastActivity
    }
}
