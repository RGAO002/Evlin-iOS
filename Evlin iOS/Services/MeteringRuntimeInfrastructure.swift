import Foundation

nonisolated struct SystemMeteringClock: MeteringClock {
    var now: Date { Date() }
}

#if DEBUG
nonisolated struct DebugAppGroupMeteringClock: MeteringClock {
    static let preferenceKey = "evlin.metering.debugClockNow"
    let defaults: UserDefaults?
    let fallback: any MeteringClock

    var now: Date {
        guard let raw = defaults?.string(forKey: Self.preferenceKey),
              let date = ISO8601DateFormatter().date(from: raw)
        else { return fallback.now }
        return date
    }
}
#endif

nonisolated enum MeteringRuntimeClock {
    static func live(defaults: UserDefaults? = UserDefaults(suiteName: "group.com.evlin.ios")) -> any MeteringClock {
#if DEBUG
        return DebugAppGroupMeteringClock(defaults: defaults, fallback: SystemMeteringClock())
#else
        return SystemMeteringClock()
#endif
    }
}

nonisolated enum MeteringOwnerMirror {
    static let suiteName = "group.com.evlin.ios"
    static let ownerKey = "evlin.childId"

    static func current() -> UUID? {
        UserDefaults(suiteName: suiteName)?
            .string(forKey: ownerKey)
            .flatMap(UUID.init(uuidString:))
    }
}
