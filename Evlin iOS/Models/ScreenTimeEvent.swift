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

    enum Kind: String, Codable, Equatable {
        case lock, unlock, sample, decision, cascade, reset, drop
        case commandEmit = "command_emit"
        case commandAck = "command_ack"
    }

    enum Source: String, Codable, Equatable {
        case manual, perAppLimit, devicePool, earnedPool, deviceCap, taskPause
    }

    struct Nums: Codable, Equatable {
        var used: Int?
        var budget: Int?
        var poolUsed: Int?
        var poolTotal: Int?
        var cap: Int?
        var remaining: Int?
        var rounded: Int?
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
