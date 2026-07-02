import Foundation

/// Talks to the new /parent/agent/exec and /parent/actions/{id}/revert
/// endpoints. Same baseURL as APIClient.
struct AgentClient {
    let baseURL: String

    init(baseURL: String) {
        self.baseURL = baseURL
    }

    func makeExecRequest(token: String) throws -> URLRequest {
        var req = URLRequest(url: URL(string: "\(baseURL)/parent/agent/exec")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 20
        req.httpBody = try JSONSerialization.data(withJSONObject: ["token": token])
        return req
    }

    func makeRevertRequest(actionID: String) -> URLRequest {
        var req = URLRequest(url: URL(string: "\(baseURL)/parent/actions/\(actionID)/revert")!)
        req.httpMethod = "POST"
        req.timeoutInterval = 15
        return req
    }

    /// Pure, testable Bearer attach. Both sendCardRequest and authedSend MUST
    /// route through this — it is the single point that turns an unauthed
    /// request into an authed one.
    static func attachBearer(_ req: URLRequest, accessToken: String?) -> URLRequest {
        guard let accessToken, !accessToken.isEmpty else { return req }
        var authed = req
        authed.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        return authed
    }

    /// Same Bearer-attach + authedData routing as sendCardRequest — the agent
    /// endpoints are gaining get_current_account server-side (observe mode
    /// first), and raw URLSession requests carry no Authorization header.
    private func authedSend(_ req: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let authed = Self.attachBearer(req, accessToken: KeychainStore.shared.load()?.accessToken)
        return try await APIClient().authedData(for: authed)
    }

    /// Confirm a staged proposal. Returns either a tool-style receipt
    /// (existing tools) or a legacy ChatAction+message bundle (when the
    /// proposal was a staged shield_app_legacy entry).
    func executeProposal(token: String) async throws -> AgentExecResult {
        let (data, http) = try await authedSend(try makeExecRequest(token: token))
        guard http.statusCode == 200 else {
            throw AgentError.serverError(
                code: http.statusCode,
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
        let (data, http) = try await authedSend(makeRevertRequest(actionID: actionID))
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

// MARK: - P5 calendar-in-chat: event.* / target.* card actions

extension AgentClient {
    /// Returned by event-select / resolve-target when the backend stages a NEW
    /// card to display next (e.g. a concrete event.create_confirm after a pick).
    struct AgentCardResponse: Decodable {
        let card_payloads: [PlanArchCardPayload]?
        let ok: Bool?
    }

    func makeEventExecRequest(token: String) throws -> URLRequest {
        var r = URLRequest(url: URL(string: "\(baseURL)/parent/agent/event-exec")!)
        r.httpMethod = "POST"; r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.timeoutInterval = 20
        r.httpBody = try JSONSerialization.data(withJSONObject: ["token": token])
        return r
    }

    func makeEventSelectRequest(continuationToken: String, eventId: String,
                                occurrenceStart: String, continuationAction: String) throws -> URLRequest {
        var r = URLRequest(url: URL(string: "\(baseURL)/parent/agent/event-select")!)
        r.httpMethod = "POST"; r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.timeoutInterval = 20
        r.httpBody = try JSONSerialization.data(withJSONObject: [
            "continuation_token": continuationToken, "event_id": eventId,
            "occurrence_start": occurrenceStart, "continuation_action": continuationAction])
        return r
    }

    func makeResolveTargetRequest(continuationToken: String, selectedIds: [String]) throws -> URLRequest {
        var r = URLRequest(url: URL(string: "\(baseURL)/parent/agent/resolve-target")!)
        r.httpMethod = "POST"; r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.timeoutInterval = 20
        r.httpBody = try JSONSerialization.data(withJSONObject: [
            "continuation_token": continuationToken, "selected_ids": selectedIds])
        return r
    }

    func makeEventScopeRequest(continuationToken: String, scope: String) throws -> URLRequest {
        var r = URLRequest(url: URL(string: "\(baseURL)/parent/agent/event-scope")!)
        r.httpMethod = "POST"; r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.timeoutInterval = 20
        r.httpBody = try JSONSerialization.data(withJSONObject: [
            "continuation_token": continuationToken, "scope": scope])
        return r
    }

    /// Sends a built request. Returns the optional follow-up card; throws
    /// AgentTargetError.expired on HTTP 410 so the caller can clear + show "expired".
    enum AgentTargetError: LocalizedError {
        case expired
        case server(Int, String)

        var errorDescription: String? {
            switch self {
            case .expired:
                return "This calendar action expired. Try again."
            case .server(let code, let detail):
                let clean = detail.trimmingCharacters(in: .whitespacesAndNewlines)
                if clean.isEmpty {
                    return "Server error \(code)."
                }
                return "Server error \(code): \(clean.prefix(160))"
            }
        }
    }

    func sendCardRequest(_ req: URLRequest) async throws -> AgentCardResponse {
        // The agent endpoints require get_current_account. Raw URLSession requests
        // sent NO Authorization header, so every Confirm/select/resolve 401'd and
        // the card "did nothing". Attach the Bearer token and route through
        // APIClient.authedData so we get the same single-flight 401-refresh + retry
        // the rest of the app uses.
        let authed = Self.attachBearer(req, accessToken: KeychainStore.shared.load()?.accessToken)
        let (data, http) = try await APIClient().authedData(for: authed)
        let code = http.statusCode
        if code == 410 { throw AgentTargetError.expired }
        guard code == 200 else {
            throw AgentTargetError.server(
                code,
                String(data: data, encoding: .utf8) ?? ""
            )
        }
        return (try? JSONDecoder().decode(AgentCardResponse.self, from: data))
            ?? AgentCardResponse(card_payloads: nil, ok: true)
    }

    func eventExec(token: String) async throws -> AgentCardResponse {
        try await sendCardRequest(try makeEventExecRequest(token: token))
    }
    func eventSelect(continuationToken: String, eventId: String,
                     occurrenceStart: String, continuationAction: String) async throws -> AgentCardResponse {
        try await sendCardRequest(try makeEventSelectRequest(
            continuationToken: continuationToken, eventId: eventId,
            occurrenceStart: occurrenceStart, continuationAction: continuationAction))
    }
    func resolveTarget(continuationToken: String, selectedIds: [String]) async throws -> AgentCardResponse {
        try await sendCardRequest(try makeResolveTargetRequest(
            continuationToken: continuationToken, selectedIds: selectedIds))
    }
    func eventScope(continuationToken: String, scope: String = "series") async throws -> AgentCardResponse {
        try await sendCardRequest(try makeEventScopeRequest(
            continuationToken: continuationToken, scope: scope))
    }
}
