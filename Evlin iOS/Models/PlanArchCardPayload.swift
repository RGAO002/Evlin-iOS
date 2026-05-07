//
//  PlanArchCardPayload.swift
//  Evlin iOS
//
//  Plan-arch dual-path: typed UI envelope sent by backend's
//  POST /parent/chat (when AGENT_PLAN_ARCH=1) and
//  POST /parent/chat/plan-patch.
//
//  ChatViewModel detects card_payload in the chat response by
//  calling PlanArchCardPayload.decodeFromChatResponseData(_:) — no edits
//  to the existing ChatResponse struct in ChatModels.swift.
//
//  NOTE: The existing CardPayload struct (Models/CardPayload.swift) is
//  the legacy UI-shell type used by the confirmation card system.
//  PlanArchCardPayload is the new Codable network model for the
//  plan-architecture dual-path. They coexist intentionally.
//

import Foundation

enum PlanArchCardType: String, Codable {
    case durationPicker = "duration_picker"
    case longDurationConfirm = "long_duration_confirm"
    case lazyTag = "lazy_tag"
    case unlockPicker = "unlock_picker"
    case rejectionWithAlternative = "rejection_with_alternative"
    case splitCommandRequest = "split_command_request"
    case dangerConfirm = "danger_confirm"
    case blockIntentConfirm = "block_intent_confirm"
}

enum PlanArchCardDanger: String, Codable {
    case low, medium, high
}

/// Type-erased Codable wrapper for the JSON-merge `patch` dict and
/// the `detail` dict, both of which are heterogeneous across card types.
struct PlanArchAnyCodable: Codable {
    let value: Any

    init(_ value: Any) { self.value = value }

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() {
            value = NSNull()
        } else if let b = try? c.decode(Bool.self) {
            value = b
        } else if let i = try? c.decode(Int.self) {
            value = i
        } else if let d = try? c.decode(Double.self) {
            value = d
        } else if let s = try? c.decode(String.self) {
            value = s
        } else if let arr = try? c.decode([PlanArchAnyCodable].self) {
            value = arr.map { $0.value }
        } else if let dict = try? c.decode([String: PlanArchAnyCodable].self) {
            value = dict.mapValues { $0.value }
        } else {
            throw DecodingError.dataCorruptedError(
                in: c,
                debugDescription: "Unsupported PlanArchAnyCodable value")
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch value {
        case is NSNull: try c.encodeNil()
        case let b as Bool: try c.encode(b)
        case let i as Int: try c.encode(i)
        case let d as Double: try c.encode(d)
        case let s as String: try c.encode(s)
        case let arr as [Any]: try c.encode(arr.map { PlanArchAnyCodable($0) })
        case let dict as [String: Any]: try c.encode(dict.mapValues { PlanArchAnyCodable($0) })
        default:
            throw EncodingError.invalidValue(
                value,
                .init(codingPath: encoder.codingPath,
                      debugDescription: "Unsupported PlanArchAnyCodable value"))
        }
    }
}

struct PlanArchCardOption: Codable, Identifiable, Hashable {
    let id = UUID()
    let label: String
    let patch: [String: PlanArchAnyCodable]
    let cancelsPlan: Bool

    enum CodingKeys: String, CodingKey {
        case label
        case patch
        case cancelsPlan = "cancels_plan"
    }

    init(label: String, patch: [String: PlanArchAnyCodable] = [:], cancelsPlan: Bool = false) {
        self.label = label
        self.patch = patch
        self.cancelsPlan = cancelsPlan
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        label = try c.decode(String.self, forKey: .label)
        patch = (try? c.decode([String: PlanArchAnyCodable].self, forKey: .patch)) ?? [:]
        cancelsPlan = (try? c.decode(Bool.self, forKey: .cancelsPlan)) ?? false
    }

    static func == (lhs: PlanArchCardOption, rhs: PlanArchCardOption) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

struct PlanArchCardPayload: Codable {
    let type: PlanArchCardType
    let title: String
    let body: String?
    let planToken: String
    let stepIndex: Int
    let options: [PlanArchCardOption]
    let detail: [String: PlanArchAnyCodable]
    let danger: PlanArchCardDanger

    enum CodingKeys: String, CodingKey {
        case type, title, body
        case planToken = "plan_token"
        case stepIndex = "step_index"
        case options, detail, danger
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        type = try c.decode(PlanArchCardType.self, forKey: .type)
        title = try c.decode(String.self, forKey: .title)
        body = try? c.decode(String.self, forKey: .body)
        planToken = try c.decode(String.self, forKey: .planToken)
        stepIndex = try c.decode(Int.self, forKey: .stepIndex)
        options = (try? c.decode([PlanArchCardOption].self, forKey: .options)) ?? []
        detail = (try? c.decode([String: PlanArchAnyCodable].self, forKey: .detail)) ?? [:]
        danger = (try? c.decode(PlanArchCardDanger.self, forKey: .danger)) ?? .low
    }

    /// Pull a PlanArchCardPayload out of arbitrary chat-response JSON Data
    /// without requiring edits to ChatResponse. Returns nil if the
    /// data is not JSON or has no card_payload key.
    static func decodeFromChatResponseData(_ data: Data) -> PlanArchCardPayload? {
        guard
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let raw = json["card_payload"]
        else { return nil }
        guard !(raw is NSNull) else { return nil }
        guard let cardData = try? JSONSerialization.data(withJSONObject: raw)
        else { return nil }
        return try? JSONDecoder().decode(PlanArchCardPayload.self, from: cardData)
    }
}
