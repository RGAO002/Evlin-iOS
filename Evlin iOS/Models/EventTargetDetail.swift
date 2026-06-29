//
//  EventTargetDetail.swift
//  Evlin iOS
//
//  P5 calendar-in-chat: pure helpers to read the loosely-typed PlanArch
//  `detail` dict (proposal_token / continuation_token / options / groups /
//  rows) out of `[String: PlanArchAnyCodable]`. No SwiftUI; unit-tested.
//

import Foundation

struct TargetOption: Identifiable, Equatable {
    let id: String              // child_profile_id / child_device_id / event_id (STABLE)
    let label: String
    var avatarURL: String? = nil
    var avatarValue: String? = nil
    var avatarColorHex: String? = nil
    var occurrenceStart: String = ""   // event.disambiguation carries this; spec §6.4

    init(id: String, label: String, occurrenceStart: String = "") {
        self.id = id
        self.label = label
        self.occurrenceStart = occurrenceStart
    }

    init(
        id: String,
        label: String,
        avatarURL: String?,
        avatarValue: String?,
        avatarColorHex: String?,
        occurrenceStart: String = ""
    ) {
        self.id = id
        self.label = label
        self.avatarURL = avatarURL
        self.avatarValue = avatarValue
        self.avatarColorHex = avatarColorHex
        self.occurrenceStart = occurrenceStart
    }
}

struct TargetGroup: Identifiable {
    // Stable UNIQUE id (not childName) so two children with the same display name
    // don't collide in ForEach and drop one group — which would make that child's
    // devices unselectable, defeating the disambiguation (code-review finding #9).
    let id: String
    let childName: String
    let options: [TargetOption]
}

/// Reads the loosely-typed PlanArch `detail` dict. The detail values are
/// `PlanArchAnyCodable`; we unwrap via JSON re-encode to stay decoder-agnostic.
struct EventTargetDetail {
    private let raw: [String: Any]

    init(_ detail: [String: PlanArchAnyCodable]) {
        // PlanArchAnyCodable is Encodable → round-trip to a plain [String: Any].
        if let data = try? JSONEncoder().encode(detail),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            raw = obj
        } else { raw = [:] }
    }

    func string(_ key: String) -> String? { raw[key] as? String }

    func options(_ key: String) -> [TargetOption] {
        (raw[key] as? [[String: Any]] ?? []).compactMap { o in
            guard let id = o["id"] as? String, let label = o["label"] as? String
            else { return nil }
            let avatar = o["avatar"] as? [String: Any]
            return TargetOption(
                id: id,
                label: label,
                avatarURL: avatar?["signed_url"] as? String,
                avatarValue: avatar?["value"] as? String,
                avatarColorHex: avatar?["color"] as? String,
                occurrenceStart: (o["occurrence_start"] as? String) ?? ""
            )
        }
    }

    func groups(_ key: String) -> [TargetGroup] {
        (raw[key] as? [[String: Any]] ?? []).enumerated().compactMap { idx, g in
            guard let name = g["child_name"] as? String else { return nil }
            let opts = (g["options"] as? [[String: Any]] ?? []).compactMap { o -> TargetOption? in
                guard let id = o["id"] as? String, let label = o["label"] as? String else { return nil }
                let avatar = o["avatar"] as? [String: Any]
                return TargetOption(
                    id: id,
                    label: label,
                    avatarURL: avatar?["signed_url"] as? String,
                    avatarValue: avatar?["value"] as? String,
                    avatarColorHex: avatar?["color"] as? String
                )
            }
            // id includes the array index so same-named children stay distinct.
            return TargetGroup(id: "\(idx)-\(name)", childName: name, options: opts)
        }
    }

    func rows(_ key: String) -> [[String: Any]] { raw[key] as? [[String: Any]] ?? [] }

    func stringList(_ key: String) -> [String] {
        (raw[key] as? [Any] ?? []).compactMap { $0 as? String }
    }
}

extension EventTargetDetail {
    /// Friendly device-local label for a UTC ISO instant, e.g. "Sun, Jun 14 · 3:35 PM".
    /// The event.result card carries occurrence_start as a raw UTC ISO string; this
    /// turns it into something a parent can read instead of "2026-06-14T19:35:00+00:00".
    /// Falls back to the raw string if unparseable.
    static func displayDateTime(_ isoUTC: String) -> String {
        guard !isoUTC.isEmpty, let date = CalendarWireTime.parseInstant(isoUTC) else { return isoUTC }
        let f = DateFormatter()
        f.locale = .current
        f.timeZone = .current
        f.dateFormat = "EEE, MMM d · h:mm a"
        return f.string(from: date)
    }

    /// "Sun, Jun 14 · 3:35 PM – 4:35 PM" for a start/end pair (both UTC ISO).
    /// Drops the date on the end side. Falls back to the single start label if end
    /// is missing/unparseable.
    static func displayDateRange(start: String, end: String) -> String {
        let startLabel = displayDateTime(start)
        guard !end.isEmpty, let e = CalendarWireTime.parseInstant(end) else { return startLabel }
        let f = DateFormatter()
        f.locale = .current
        f.timeZone = .current
        f.dateFormat = "h:mm a"
        return "\(startLabel) – \(f.string(from: e))"
    }
}
