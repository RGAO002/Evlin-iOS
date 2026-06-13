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
    var occurrenceStart: String = ""   // event.disambiguation carries this; spec §6.4
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
            return TargetOption(id: id, label: label,
                                occurrenceStart: (o["occurrence_start"] as? String) ?? "")
        }
    }

    func groups(_ key: String) -> [TargetGroup] {
        (raw[key] as? [[String: Any]] ?? []).enumerated().compactMap { idx, g in
            guard let name = g["child_name"] as? String else { return nil }
            let opts = (g["options"] as? [[String: Any]] ?? []).compactMap { o -> TargetOption? in
                guard let id = o["id"] as? String, let label = o["label"] as? String else { return nil }
                return TargetOption(id: id, label: label)
            }
            // id includes the array index so same-named children stay distinct.
            return TargetGroup(id: "\(idx)-\(name)", childName: name, options: opts)
        }
    }

    func rows(_ key: String) -> [[String: Any]] { raw[key] as? [[String: Any]] ?? [] }
}
