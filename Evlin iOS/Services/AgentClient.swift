import Foundation

/// Talks to the new /parent/agent/exec and /parent/actions/{id}/revert
/// endpoints. Same baseURL as APIClient.
struct AgentClient {
    let baseURL: String

    init(baseURL: String) {
        self.baseURL = baseURL
    }

    /// Confirm a staged proposal. Returns either a tool-style receipt
    /// (existing tools) or a legacy ChatAction+message bundle (when the
    /// proposal was a staged shield_app_legacy entry).
    func executeProposal(token: String) async throws -> AgentExecResult {
        let url = URL(string: "\(baseURL)/parent/agent/exec")!
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 20
        req.httpBody = try JSONSerialization.data(withJSONObject: ["token": token])
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            throw AgentError.serverError(
                code: (resp as? HTTPURLResponse)?.statusCode ?? 0,
                detail: String(data: data, encoding: .utf8) ?? "")
        }
        let decoded = try JSONDecoder().decode(ExecResponseDTO.self, from: data)
        if let receipt = decoded.receipt {
            return .receipt(receipt)
        }
        if let plural = decoded.legacy_actions, !plural.isEmpty {
            return .legacyActions(
                results: plural,
                message: decoded.message,
                reasoning: decoded.reasoning
            )
        }
        return .legacyAction(
            action: decoded.legacy_action,
            message: decoded.message,
            reasoning: decoded.reasoning
        )
    }

    /// Revert a previously executed action by undo_token.
    func revertAction(actionID: String) async throws -> RevertResult {
        let url = URL(string: "\(baseURL)/parent/actions/\(actionID)/revert")!
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 15
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else {
            throw AgentError.serverError(code: 0, detail: "no response")
        }
        if http.statusCode == 410 {
            throw AgentError.expired
        }
        if http.statusCode != 200 {
            throw AgentError.serverError(
                code: http.statusCode,
                detail: String(data: data, encoding: .utf8) ?? "")
        }
        return try JSONDecoder().decode(RevertResult.self, from: data)
    }
}

struct RevertResult: Codable {
    let revertedActionID: String
    let newUndoToken: String?

    enum CodingKeys: String, CodingKey {
        case revertedActionID = "reverted_action_id"
        case newUndoToken = "new_undo_token"
    }
}

/// Result of /parent/agent/exec. Backend returns either a tool-style
/// receipt (existing tools) or a legacy ChatAction+message bundle (when
/// the proposal was a staged shield_app_legacy entry — see backend
/// parent_agent.py / parent_chat.py for staging).
///
/// IMPORTANT: legacy action uses `APIClient.ChatActionResponse` — the same
/// type that decodes /parent/chat's `action` field. The other `ChatAction`
/// in `Models/ChatModels.swift` is a legacy enum unrelated to /parent/chat
/// responses; do not use it here.
enum AgentExecResult {
    case receipt(ReceiptDTO)
    /// Singular legacy action — kept for backwards compat with old
    /// proposals in flight at deploy time. New code emits `legacyActions`.
    case legacyAction(action: APIClient.ChatActionResponse?, message: String?, reasoning: String?)
    /// Plural: each entry is one staged sub-action's exec result. iOS
    /// appends a separate ChatMessage + starts a separate ack-poll per
    /// item with a non-nil command_id.
    case legacyActions(results: [LegacyActionResult], message: String?, reasoning: String?)
}

struct LegacyActionResult: Decodable {
    let action: APIClient.ChatActionResponse?
    let message: String?
}

/// Server-side response shape mirroring backend ExecResponse.
private struct ExecResponseDTO: Decodable {
    let receipt: ReceiptDTO?
    let legacy_action: APIClient.ChatActionResponse?
    let legacy_actions: [LegacyActionResult]?
    let message: String?
    let reasoning: String?
}

enum AgentError: LocalizedError {
    case expired
    case serverError(code: Int, detail: String)

    var errorDescription: String? {
        switch self {
        case .expired: return "This action expired. Try again."
        case .serverError(let code, let detail):
            return "Server error \(code): \(detail.prefix(120))"
        }
    }
}
