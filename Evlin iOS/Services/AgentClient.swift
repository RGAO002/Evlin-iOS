import Foundation

/// Talks to the new /parent/agent/exec and /parent/actions/{id}/revert
/// endpoints. Same baseURL as APIClient.
struct AgentClient {
    let baseURL: String

    init(baseURL: String) {
        self.baseURL = baseURL
    }

    /// Confirm a staged proposal. Returns the executed receipt.
    func executeProposal(token: String) async throws -> ReceiptDTO {
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
        return try JSONDecoder().decode(ReceiptDTO.self, from: data)
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
