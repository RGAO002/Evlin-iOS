//
//  PlanPatchClient.swift
//  Evlin iOS
//
//  Posts card-driven patches back to the backend's
//  POST /parent/chat/plan-patch endpoint. Returns the next ChatTurnResult
//  (either an executed plan's message, a follow-up card, or a cancellation /
//  rejection text). HTTP 410 maps to .expired.
//

import Foundation

enum PlanPatchOutcome {
    case executed(message: String, reasoning: String?, queuedCommands: [PlanPatchQueuedCommand])
    case followUpCard(PlanArchCardPayload)
    case rejected(message: String)
    case expired(message: String)
    case error(Error)
}

struct PlanPatchQueuedCommand: Codable, Sendable {
    let commandID: UUID
    let action: String?
    let targetDisplay: String?
    let durationMinutes: Int?
    let tier: String?

    enum CodingKeys: String, CodingKey {
        case commandID = "command_id"
        case action
        case targetDisplay = "target_display"
        case durationMinutes = "duration_minutes"
        case tier
    }
}

struct PlanPatchClient {
    let baseURL: URL
    let session: URLSession

    init(baseURL: URL, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
    }

    func submitPatch(
        planToken: String,
        stepIndex: Int,
        patch: [String: Any] = [:],
        cancel: Bool = false,
        clientAliasState: [String: Any]? = nil,
        familyID: UUID? = nil,
        childDeviceID: UUID? = nil
    ) async -> PlanPatchOutcome {
        var body: [String: Any] = [
            "plan_token": planToken,
            "step_index": stepIndex,
            "patch": patch,
            "cancel": cancel,
        ]
        if let state = clientAliasState {
            body["client_alias_state"] = state
        }
        if let id = familyID { body["family_id"] = id.uuidString }
        if let id = childDeviceID { body["child_device_id"] = id.uuidString }

        do {
            let url = baseURL.appendingPathComponent("/parent/chat/plan-patch")
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)

            let (data, response) = try await session.data(for: req)
            guard let http = response as? HTTPURLResponse else {
                return .error(URLError(.badServerResponse))
            }

            if http.statusCode == 410 {
                let msg = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["detail"] as? String ?? "That request has expired"
                return .expired(message: msg)
            }
            guard (200..<300).contains(http.statusCode) else {
                return .error(URLError(.badServerResponse))
            }

            // Parse PlanPatchResponse: {message, reasoning?, card_payload?, expired}
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return .error(URLError(.cannotDecodeContentData))
            }
            let message = json["message"] as? String ?? ""
            let reasoning = json["reasoning"] as? String

            if let card = PlanArchCardPayload.decodeFromChatResponseData(data) {
                return .followUpCard(card)
            }
            if json["expired"] as? Bool == true {
                return .expired(message: message)
            }
            let queuedCommands: [PlanPatchQueuedCommand]
            if let raw = json["queued_commands"],
               JSONSerialization.isValidJSONObject(["queued_commands": raw]),
               let payload = try? JSONSerialization.data(withJSONObject: raw) {
                queuedCommands = (try? JSONDecoder().decode([PlanPatchQueuedCommand].self, from: payload)) ?? []
            } else {
                queuedCommands = []
            }
            return .executed(message: message, reasoning: reasoning, queuedCommands: queuedCommands)
        } catch {
            return .error(error)
        }
    }
}
