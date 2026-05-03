import Foundation

/// Parent-side wrapper for `/api/v1/parent/*` BigKid endpoints.
///
/// Mirrors `BigKidAPIClient` (which is child-scoped) but talks to the new
/// parent endpoints added in `bigkid_parent.py`. Used by `ProfileView` and
/// `TaskDetailSheet` to load the kid's real task list and round-trip
/// approve / redo / bypass-respond actions.
///
/// This is intentionally a separate object from the chat-focused `APIClient`
/// so it can carry its own JSON decoder configured for the BigKid wire format
/// (snake_case + fractional-second ISO8601). Init takes the same baseURL as
/// `APIClient.baseURL` (e.g. `https://…/api/v1`).
final class BigKidParentClient {
    let baseURL: URL
    private let session: URLSession

    init(baseURL: URL, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
    }

    convenience init?(baseURLString: String) {
        guard let url = URL(string: baseURLString) else { return nil }
        self.init(baseURL: url)
    }

    // MARK: - Reads

    func fetchKidState(childId: UUID) async throws -> ChildStateResponse {
        try await get("/parent/state/\(childId.uuidString)")
    }

    // MARK: - Tasks

    func createTask(
        childId: UUID, title: String, description: String,
        category: BigKidTaskCategory, due: String?
    ) async throws -> BigKidTask {
        var body: [String: Any] = [
            "child_id": childId.uuidString,
            "title": title,
            "description": description,
            "category": category.rawValue,
        ]
        if let due, !due.isEmpty { body["due"] = due }
        return try await postJSON("/parent/task", body: body)
    }

    func reviewTask(
        taskId: UUID, decision: TaskReviewDecision, redoReason: String? = nil
    ) async throws -> BigKidTask {
        var body: [String: Any] = ["decision": decision.rawValue]
        if let redoReason, !redoReason.isEmpty { body["redo_reason"] = redoReason }
        return try await postJSON("/parent/task/\(taskId.uuidString)/review", body: body)
    }

    func deleteTask(taskId: UUID) async throws {
        let req = try makeRequest(path: "/parent/task/\(taskId.uuidString)", method: "DELETE")
        _ = try await sendVoid(req)
    }

    // MARK: - Bypass

    func respondBypass(
        bypassId: UUID, decision: BypassRespondDecision, message: String? = nil
    ) async throws -> BypassRequest {
        var body: [String: Any] = ["decision": decision.rawValue]
        if let message, !message.isEmpty { body["message"] = message }
        return try await postJSON("/parent/bypass/\(bypassId.uuidString)/respond", body: body)
    }

    // MARK: - Internal

    private func makeRequest(path: String, method: String) throws -> URLRequest {
        guard let url = URL(string: baseURL.absoluteString + path) else {
            throw URLError(.badURL)
        }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.timeoutInterval = 20
        return req
    }

    private func makeJSONRequest(path: String, method: String, body: [String: Any]) throws -> URLRequest {
        var req = try makeRequest(path: path, method: method)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        return req
    }

    private func get<T: Decodable>(_ path: String) async throws -> T {
        let req = try makeRequest(path: path, method: "GET")
        return try await perform(req)
    }

    private func postJSON<T: Decodable>(_ path: String, body: [String: Any]) async throws -> T {
        let req = try makeJSONRequest(path: path, method: "POST", body: body)
        return try await perform(req)
    }

    private func perform<T: Decodable>(_ req: URLRequest) async throws -> T {
        let (data, resp) = try await session.data(for: req)
        try Self.validate(resp, data: data)
        return try JSONDecoder.bigKid.decode(T.self, from: data)
    }

    private func sendVoid(_ req: URLRequest) async throws -> Void {
        let (data, resp) = try await session.data(for: req)
        try Self.validate(resp, data: data)
    }

    private static func validate(_ resp: URLResponse, data: Data) throws {
        guard let http = resp as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        guard 200..<300 ~= http.statusCode else {
            let detail = String(data: data, encoding: .utf8) ?? "<no body>"
            throw BigKidAPIError(status: http.statusCode, detail: detail)
        }
    }
}

enum TaskReviewDecision: String {
    case approve, redo
}

enum BypassRespondDecision: String {
    case approve, deny
}

// MARK: - Mapping BigKidTask → TaskItem (parent-side UI model)

extension TaskItem {
    /// Convert a backend BigKid task into the parent-side `TaskItem` consumed
    /// by `ProfileView` / `TaskDetailSheet`.
    ///
    /// - Parameter sequenceID: A stable Int handle for SwiftUI's `Identifiable`
    ///   contract. The parent UI was originally built for mock data with Int
    ///   ids; we keep that contract intact and stash the real UUID on
    ///   `backendID` so backend round-trips know which task to act on.
    static func from(backend t: BigKidTask, sequenceID: Int) -> TaskItem {
        // Map backend status+phase+bypass → parent-UI TaskItem.State
        let state: TaskItem.State = {
            if let bp = t.bypass {
                switch bp.status {
                case .pending:   return .bypass
                case .approved:  return .bypassed
                case .denied, .withdrawn: break
                }
            }
            if t.status == .done { return .done }
            if t.status == .submitted { return .review }
            if t.status == .overdue { return .overdue }
            return .pending
        }()

        let category: String = {
            switch t.category {
            case .chores: return "Chore"
            case .homework: return "Homework"
            case .selfCare: return "Routine"
            }
        }()

        let photos: [String] = (t.evidencePhotoUrl?.absoluteString).map { [$0] } ?? []

        // Note priority: bypass reason > kid's evidence note > parent's redo
        // reason. The parent-UI's bypass status card reads `task.note` to
        // render the kid's bypass copy; the submission card under "review"
        // reads it to show the kid's "Took longer than I thought!"-style
        // note next to the photo grid.
        let note: String? = t.bypass.map { $0.reason }
            ?? t.evidenceNote
            ?? t.redoReason

        return TaskItem(
            id: sequenceID,
            title: t.title,
            state: state,
            iconSystemName: state == .done ? "checkmark" : nil,
            category: category,
            description: t.description,
            photos: photos,
            note: note,
            submittedAt: nil,                // backend has timestamps; parent UI uses string
            dueLabel: t.due,
            backendID: t.id,
            backendBypassID: t.bypass?.id
        )
    }
}
