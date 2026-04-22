import Foundation
import Combine

class APIClient: ObservableObject {
    @Published var baseURL: String

    static let defaultURL = "https://adaptive-engine-production.up.railway.app/api/v1"

    init(baseURL: String = "") {
        let saved = UserDefaults.standard.string(forKey: "serverURL") ?? ""
        // Ignore old localhost/LAN URLs
        let useSaved = !saved.isEmpty && !saved.contains("192.168") && !saved.contains("localhost")
        self.baseURL = baseURL.isEmpty
            ? (useSaved ? saved : Self.defaultURL)
            : baseURL
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
