import Combine
import Foundation

/// All `/api/v1/child/*` endpoints from spec §8.
/// Uses `X-Child-Id` header (spec §9) — auth shim for v1.
final class BigKidAPIClient: ObservableObject {
    @Published var baseURL: URL
    let childId: UUID
    private let session: URLSession

    init(baseURL: URL, childId: UUID, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.childId = childId
        self.session = session
    }

    nonisolated deinit {}

    // MARK: - State

    func fetchState() async throws -> ChildStateResponse {
        try await get("/child/state")
    }

    func reportHeartbeat(globalEffectiveState: [String: Any]? = nil) async throws {
        var body: [String: Any] = [
            "device_id": childId.uuidString,
            "os_version": DeviceInfoProvider.current().os_version,
        ]
        if let globalEffectiveState {
            body["global_effective_state"] = globalEffectiveState
        }
        let req = try makeJSONRequest(path: "/child/heartbeat", method: "POST", body: body)
        _ = try await sendVoid(req)
    }

    // MARK: - Tasks

    /// Submit one or more evidence photos for a task. The `photos` array
    /// is the FULL submission — backend replaces any prior evidence with
    /// it. Order is preserved (first = primary). Per-photo cap 5MB,
    /// total cap 6 photos (matches the backend endpoint contract).
    func submitEvidence(taskId: UUID, photos: [Data], note: String?) async throws -> BigKidTask {
        precondition(!photos.isEmpty, "submitEvidence requires at least one photo")
        var req = try makeRequest(path: "/child/task/\(taskId)/evidence", method: "POST")
        // Photo uploads are far heavier than the JSON calls makeRequest's 20s
        // default targets. Even downscaled, a multi-photo multipart body over a
        // weak cellular link needs more headroom before timing out.
        req.timeoutInterval = 60
        let boundary = UUID().uuidString
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.httpBody = Self.multipartBody(boundary: boundary, photos: photos, note: note)
        return try await perform(req)
    }

    // MARK: - Bypass

    func submitBypass(taskId: UUID, reason: String) async throws -> BypassRequest {
        let body: [String: Any] = ["task_id": taskId.uuidString, "reason": reason]
        return try await postJSON("/child/bypass", body: body)
    }

    // MARK: - Reflection

    func reflectionStepComplete(rid: UUID, step: BigKidReflectionStep) async throws -> ReflectionRequest {
        try await postJSON("/child/reflection/\(rid)/step-complete", body: ["step": step.rawValue])
    }

    func reflectionQuizAnswer(rid: UUID, questionIndex: Int, selectedIndex: Int) async throws -> QuizAnswerOutcome {
        try await postJSON("/child/reflection/\(rid)/quiz-answer",
                           body: ["question_index": questionIndex, "selected_index": selectedIndex])
    }

    func reflectionEssay(rid: UUID, text: String) async throws -> ReflectionRequest {
        try await postJSON("/child/reflection/\(rid)/essay", body: ["text": text])
    }

    func reflectionNudge(rid: UUID) async throws -> NudgeOutcome {
        try await postJSON("/child/reflection/\(rid)/nudge", body: [:])
    }

    func reflectionAck(rid: UUID) async throws {
        let req = try makeRequest(path: "/child/reflection/\(rid)/ack", method: "POST")
        _ = try await sendVoid(req)
    }

    // MARK: - Day-end acks

    func ackDailyComplete() async throws {
        let req = try makeRequest(path: "/child/daily-complete/ack", method: "POST")
        _ = try await sendVoid(req)
    }

    func ackScreenTimeFinished() async throws {
        let req = try makeRequest(path: "/child/screen-time-finished/ack", method: "POST")
        _ = try await sendVoid(req)
    }

    // MARK: - Time consumption

    // MARK: - DEBUG

    /// Reset this child's task list / reflection / time pool back to the
    /// initial fixture state. DEBUG-only convenience for re-testing the
    /// task flow without redeploying. Server endpoint:
    /// POST /parent/_debug/reset/{child_id}
    func debugResetState() async throws {
        // /parent/_debug/... lives outside /child/* so we build the URL
        // manually rather than going through makeRequest().
        guard let url = URL(string:
            baseURL.absoluteString + "/parent/_debug/reset/\(childId.uuidString)"
        ) else { throw URLError(.badURL) }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 15
        let (data, resp) = try await session.data(for: req)
        try Self.validate(resp, data: data)
    }

    func reportTimeUse(minutesUsed: Int) async throws {
        let req = try makeJSONRequest(path: "/child/time-consumption",
                                       method: "POST", body: ["minutes_used": minutesUsed])
        _ = try await sendVoid(req)
    }

    // MARK: - Internal

    func makeRequest(path: String, method: String) throws -> URLRequest {
        guard let url = URL(string: baseURL.absoluteString + path) else {
            throw URLError(.badURL)
        }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue(childId.uuidString, forHTTPHeaderField: "X-Child-Id")
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
        var req = try makeRequest(path: path, method: "GET")
        // Bypass URLCache for kid-state polls. Without this, URLSession's
        // default cache policy can return a stale '/child/state' body for
        // up to several seconds even though we explicitly fired a fresh
        // request — that's why the kid sometimes missed a reflection the
        // parent had just confirmed in chat. State endpoints are
        // realtime; never serve them from cache.
        req.cachePolicy = .reloadIgnoringLocalCacheData
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

    private static func multipartBody(boundary: String, photos: [Data], note: String?) -> Data {
        var body = Data()
        let crlf = "\r\n"
        // One `photos` part per image — FastAPI's `list[UploadFile]` reads
        // repeated form fields with the same name. Filenames just need to
        // be distinct enough that the multipart parser doesn't trip; the
        // backend ignores them and assigns its own UUID per upload.
        for (idx, data) in photos.enumerated() {
            body.append("--\(boundary)\(crlf)".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"photos\"; filename=\"evidence-\(idx).jpg\"\(crlf)".data(using: .utf8)!)
            body.append("Content-Type: image/jpeg\(crlf)\(crlf)".data(using: .utf8)!)
            body.append(data)
            body.append(crlf.data(using: .utf8)!)
        }
        if let note, !note.isEmpty {
            body.append("--\(boundary)\(crlf)".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"note\"\(crlf)\(crlf)".data(using: .utf8)!)
            body.append(note.data(using: .utf8)!)
            body.append(crlf.data(using: .utf8)!)
        }
        body.append("--\(boundary)--\(crlf)".data(using: .utf8)!)
        return body
    }
}

struct BigKidAPIError: Error, CustomStringConvertible {
    let status: Int
    let detail: String
    var description: String { "BigKidAPIError(\(status)): \(detail)" }
}

struct QuizAnswerOutcome: Codable, Equatable, Sendable {
    let correct: Bool
    let allCorrect: Bool
    let score: Int
}

struct NudgeOutcome: Codable, Equatable, Sendable {
    let endsAt: Date
}
