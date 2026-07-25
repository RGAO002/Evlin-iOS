import Foundation

/// One structured screen-time observability event. Emitted on the kid
/// extension, kid app, parent app, and (later) backend, serialized as a
/// single JSON line for the App-Group ring buffer and os_log.
///
/// Membership: this file MUST be in BOTH the `Evlin iOS` and
/// `EvlinDeviceActivityMonitor` targets.
struct ScreenTimeEvent: Codable, Equatable {

    enum Emitter: String, Codable, Equatable {
        case parentApp = "parent_app"
        case kidApp = "kid_app"
        case kidExtension = "kid_extension"
        case backend = "backend"
    }

    /// Wire constraint: the backend column is `String(16)` and the pydantic
    /// schema enforces `max_length=16` — a longer raw value 422s the WHOLE
    /// batch, which stalls the uploader watermark for every other event too.
    /// So every case here MUST stay ≤ 16 characters. The metering flight
    /// recorder (A3) therefore uses the `metering_<leg>` family instead of a
    /// dotted `metering.<leg>` namespace, matching the existing
    /// `command_emit` / `command_ack` snake_case convention.
    enum Kind: String, Codable, Equatable {
        case lock, unlock, sample, decision, cascade, reset, drop
        case commandEmit = "command_emit"
        case commandAck = "command_ack"

        // MARK: A3 metering flight recorder (all ≤ 16 chars)

        /// A DeviceActivity threshold callback entered the extension process.
        case meteringCallback = "metering_cb"
        /// A v2 threshold callback reached a verdict in `DeviceEpochStore`.
        case meteringGuard = "metering_guard"
        /// Parked (birth-race) callbacks were replayed.
        case meteringReplay = "metering_replay"
        /// A sample's network leg (queued / HTTP result / terminal state).
        case meteringSample = "metering_sample"
        /// Credited progress was absorbed into the base before a re-arm.
        case meteringRearm = "metering_rearm"
        /// Daemon coverage flipped, with the failing comparison named.
        case meteringCover = "metering_cover"
        /// Canonical midnight rollover prepared — or threw.
        case meteringDay = "metering_day"
        /// A work queue item reached a terminal failure.
        case meteringWork = "metering_work"
        /// A previously silent `catch` in the metering/BigKid recovery paths.
        case meteringError = "metering_error"
        /// Watchdog self-check result (green heartbeat or a named red).
        case meteringWatch = "metering_watch"
        /// Operator-triggered repair (re-kick / nuclear reset) and its report.
        case meteringRepair = "metering_repair"
    }

    enum Source: String, Codable, Equatable {
        case manual, perAppLimit, devicePool, earnedPool, deviceCap, taskPause
    }

    /// Numeric side-car. Serialized straight into the backend's free-form
    /// `nums` JSONB column, so new optional members need no wire change.
    /// `nil` members are omitted by `JSONEncoder`, keeping old lines byte-stable.
    struct Nums: Codable, Equatable {
        var used: Int?
        var budget: Int?
        var poolUsed: Int?
        var poolTotal: Int?
        var cap: Int?
        var remaining: Int?
        var rounded: Int?

        // MARK: A3 metering flight recorder

        /// `epoch.baseAcceptedMinutes` at the moment of the decision.
        var base: Int?
        /// `epoch.lastRawThresholdMinutes` at the moment of the decision.
        var raw: Int?
        /// The threshold minutes carried by the callback / ladder rung.
        var threshold: Int?
        /// `epoch.excludedWhilePausedMinutes` at the moment of the decision.
        var excluded: Int?
        /// Generic counter (replayed callbacks, activities, events, …).
        var count: Int?
        /// HTTP status of the network leg this event describes.
        var http: Int?
    }

    struct Transition: Codable, Equatable {
        var before: String?
        var after: String?
    }

    var ts: String
    var emitter: Emitter
    var deviceID: String?
    var dayKey: String?
    var kind: Kind
    var source: Source?
    var app: String?
    var reason: String?
    var nums: Nums?
    var transition: Transition?
    var policyGen: Int?
    var corrID: String?

    func jsonLine() -> String {
        let enc = JSONEncoder()
        enc.outputFormatting = [.withoutEscapingSlashes]
        guard let data = try? enc.encode(self),
              let s = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return s
    }

    static func from(jsonLine line: String) -> ScreenTimeEvent? {
        guard let data = line.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(ScreenTimeEvent.self, from: data)
    }
}
