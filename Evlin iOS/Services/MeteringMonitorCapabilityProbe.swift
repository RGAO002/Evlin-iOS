#if DEBUG
import Foundation

nonisolated struct ProbeSchedulePlan: Equatable, Sendable {
    let stoppedActivityName: String
    let activeActivityName: String
    let stoppedStart: Date
    let supersededActiveStart: Date
    let replacementActiveStart: Date
    let end: Date
    let canonicalTimezone: String

    func dateComponents(for date: Date) -> DateComponents? {
        guard let timeZone = TimeZone(identifier: canonicalTimezone) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar.dateComponents(in: timeZone, from: date)
    }
}

nonisolated enum MeteringMonitorCapabilityProbe {
    static let activityPrefix = "evlin.metering.probe."
    static let logKey = "evlin.spike.meteringMonitorProbeLog"
    static let callbackKey = "evlin.spike.meteringMonitorProbeCallback"

    private static let logLimit = 30

    static func activityName(origin: String, sequence: Int, role: String) -> String {
        "\(activityPrefix)\(origin).\(sequence).\(role)"
    }

    static func isProbeActivity(_ raw: String) -> Bool {
        raw.hasPrefix(activityPrefix)
    }

    static func schedulePlan(
        origin: String,
        sequence: Int,
        now: Date,
        canonicalTimezone: String
    ) -> ProbeSchedulePlan? {
        guard TimeZone(identifier: canonicalTimezone) != nil else { return nil }

        return ProbeSchedulePlan(
            stoppedActivityName: activityName(
                origin: origin,
                sequence: sequence,
                role: "stopped"
            ),
            activeActivityName: activityName(
                origin: origin,
                sequence: sequence,
                role: "active"
            ),
            stoppedStart: now.addingTimeInterval(45),
            supersededActiveStart: now.addingTimeInterval(30),
            replacementActiveStart: now.addingTimeInterval(60),
            end: now.addingTimeInterval(16 * 60),
            canonicalTimezone: canonicalTimezone
        )
    }

    static func append(_ line: String, defaults: UserDefaults?) {
        guard let defaults else { return }
        var log = defaults.stringArray(forKey: logKey) ?? []
        log.append(line)
        if log.count > logLimit {
            log.removeFirst(log.count - logLimit)
        }
        defaults.set(log, forKey: logKey)
    }
}
#endif
