import Foundation
import Combine

class APIClient: ObservableObject {
    @Published var baseURL: String

    static let defaultURL = "https://adaptive-engine-production.up.railway.app/api/v1"

    init(baseURL: String = "") {
        let saved = UserDefaults.standard.string(forKey: "serverURL") ?? ""
        // Ignore old localhost/LAN URLs
        let useSaved = !saved.isEmpty && !saved.contains("192.168") && !saved.contains("localhost")
        let raw = baseURL.isEmpty
            ? (useSaved ? saved : Self.defaultURL)
            : baseURL
        // Guard against missing scheme (user typed raw host in Settings)
        if raw.hasPrefix("http://") || raw.hasPrefix("https://") {
            self.baseURL = raw
        } else {
            self.baseURL = "https://" + raw
        }
    }

    // MARK: - Parent Chat

    struct ChatRequest: Codable {
        let message: String
        let child_name: String
        let history: [[String: String]]
    }

    struct ChatResponse: Codable {
        let message: String
        let reasoning: String?
        let action: [String: AnyCodable]?
    }

    func sendChatMessage(message: String, childName: String, history: [[String: String]]) async throws -> ChatResponse {
        // Retry up to 3 times — the Gemini backend occasionally returns 500/503
        // ("This model is currently experiencing high demand"). A short backoff
        // almost always resolves it on the second try.
        var lastStatus = 0
        for attempt in 0..<3 {
            let url = URL(string: "\(baseURL)/parent/chat")!
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.timeoutInterval = 30

            let body = ChatRequest(message: message, child_name: childName, history: history)
            request.httpBody = try JSONEncoder().encode(body)

            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                let http = response as? HTTPURLResponse
                lastStatus = http?.statusCode ?? 0

                if lastStatus == 200 {
                    return try JSONDecoder().decode(ChatResponse.self, from: data)
                }
                // Retry on upstream Gemini overload (500/503)
                if lastStatus == 500 || lastStatus == 503, attempt < 2 {
                    try? await Task.sleep(nanoseconds: UInt64(800_000_000 * (attempt + 1)))
                    continue
                }
                throw APIError.serverError(lastStatus)
            } catch let err as APIError {
                throw err
            } catch {
                // Transient network error — retry once
                if attempt < 2 {
                    try? await Task.sleep(nanoseconds: 600_000_000)
                    continue
                }
                throw error
            }
        }
        throw APIError.serverError(lastStatus)
    }

    func saveServerURL(_ url: String) {
        baseURL = url
        UserDefaults.standard.set(url, forKey: "serverURL")
    }
}

// MARK: - Error

enum APIError: LocalizedError {
    case serverError(Int)

    var errorDescription: String? {
        switch self {
        case .serverError(let code): return "Server error (\(code))"
        }
    }
}

// MARK: - Three-tier lock command APIs

struct PollTargetDTO: Codable {
    let bundle_id: String?
    let list_name: String?
    let has_pending_blob: Bool?
    let category_hint: String?
    let original_request: String
    let target_display: String?
}

struct PollCommandDTO: Codable {
    let command_id: UUID
    let action: String
    let tier: String?
    let target: PollTargetDTO
    let duration_minutes: Int?
    let issued_at: String
}

extension APIClient {
    /// Child polls for queued commands.
    func pollCommands(deviceID: UUID) async throws -> [PollCommandDTO] {
        var comps = URLComponents(string: "\(baseURL)/child/commands")!
        comps.queryItems = [URLQueryItem(name: "device_id", value: deviceID.uuidString)]
        let (data, response) = try await URLSession.shared.data(from: comps.url!)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { return [] }
        return try JSONDecoder().decode([PollCommandDTO].self, from: data)
    }

    /// Child posts an ack for a command.
    func ack(commandID: UUID, status: String, detail: [String: Any]? = nil) async throws {
        let url = URL(string: "\(baseURL)/child/ack")!
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body: [String: Any] = [
            "command_id": commandID.uuidString,
            "status": status,
        ]
        if let detail = detail { body["detail"] = detail }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        _ = try await URLSession.shared.data(for: req)
    }

    /// Child fetches an ephemeral Max-mode selection blob (one-shot).
    func fetchPendingBlob(commandID: UUID) async throws -> Data? {
        var comps = URLComponents(string: "\(baseURL)/child/pending-blob")!
        comps.queryItems = [URLQueryItem(name: "command_id", value: commandID.uuidString)]
        let (data, resp) = try await URLSession.shared.data(from: comps.url!)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        struct Envelope: Codable { let blob_base64: String }
        let env = try JSONDecoder().decode(Envelope.self, from: data)
        return Data(base64Encoded: env.blob_base64)
    }

    /// Parent polls for a command's ack status.
    func fetchAckStatus(commandID: UUID) async throws -> (status: String, detail: [String: Any]?) {
        var comps = URLComponents(string: "\(baseURL)/parent/ack-status")!
        comps.queryItems = [URLQueryItem(name: "command_id", value: commandID.uuidString)]
        let (data, _) = try await URLSession.shared.data(from: comps.url!)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        return (json["status"] as? String ?? "pending", json["detail"] as? [String: Any])
    }

    // MARK: - Saved list metadata

    struct CreateListParams {
        let familyID: UUID
        let owningDeviceID: UUID
        let name: String
        let description: String?
        let mode: String  // "child_device" | "parent_device"
    }

    @discardableResult
    func upsertSavedListMeta(_ p: CreateListParams) async throws -> UUID {
        let url = URL(string: "\(baseURL)/family/saved-lists")!
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body: [String: Any] = [
            "family_id": p.familyID.uuidString,
            "owning_device_id": p.owningDeviceID.uuidString,
            "name": p.name,
            "mode": p.mode,
        ]
        if let d = p.description { body["description"] = d }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, _) = try await URLSession.shared.data(for: req)
        struct R: Codable { let id: UUID }
        return try JSONDecoder().decode(R.self, from: data).id
    }
}

// MARK: - AnyCodable (for flexible action dict)

struct AnyCodable: Codable {
    let value: Any

    init(_ value: Any) { self.value = value }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let int = try? container.decode(Int.self) { value = int }
        else if let double = try? container.decode(Double.self) { value = double }
        else if let string = try? container.decode(String.self) { value = string }
        else if let bool = try? container.decode(Bool.self) { value = bool }
        else { value = "" }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        if let int = value as? Int { try container.encode(int) }
        else if let double = value as? Double { try container.encode(double) }
        else if let string = value as? String { try container.encode(string) }
        else if let bool = value as? Bool { try container.encode(bool) }
        else { try container.encode("") }
    }
}
