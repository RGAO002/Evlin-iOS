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

    // MARK: - State

    func fetchState() async throws -> ChildStateResponse {
        try await get("/child/state")
    }

    // MARK: - Tasks

    func submitEvidence(taskId: UUID, photoData: Data, note: String?) async throws -> BigKidTask {
        var req = try makeRequest(path: "/child/task/\(taskId)/evidence", method: "POST")
        let boundary = UUID().uuidString
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.httpBody = Self.multipartBody(boundary: boundary, photoData: photoData, note: note)
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

    private static func multipartBody(boundary: String, photoData: Data, note: String?) -> Data {
        var body = Data()
        let crlf = "\r\n"
        body.append("--\(boundary)\(crlf)".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"photo\"; filename=\"evidence.jpg\"\(crlf)".data(using: .utf8)!)
        body.append("Content-Type: image/jpeg\(crlf)\(crlf)".data(using: .utf8)!)
        body.append(photoData)
        body.append(crlf.data(using: .utf8)!)
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
