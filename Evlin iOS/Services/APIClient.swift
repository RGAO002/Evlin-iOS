import Foundation
import Combine

class APIClient: ObservableObject {
    @Published var baseURL: String

    static let defaultURL = "https://evlin-backend.onrender.com/api/v1"

    /// One-shot migration: 2026-05-07 backend split moved the Evlin Backend
    /// from the old `adaptive-engine` Railway service to its own Render
    /// service. Existing users have the old URL persisted in UserDefaults
    /// and won't see the new default unless we rewrite the saved value.
    /// Only the first launch after upgrade hits this branch.
    private static let legacyURLs: Set<String> = [
        "https://adaptive-engine-production.up.railway.app/api/v1",
        "http://adaptive-engine-production.up.railway.app/api/v1",
    ]

    init(baseURL: String = "") {
        var saved = UserDefaults.standard.string(forKey: "serverURL") ?? ""
        if Self.legacyURLs.contains(saved) {
            saved = Self.defaultURL
            UserDefaults.standard.set(saved, forKey: "serverURL")
        }
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
        let family_id: String?  // UUID string — required for command queueing
        let force_confirmations: [String]
        // BigKid child id (UUID string). Used by `reflect` action only.
        // Same source as the BigKid debug panel: @AppStorage("evlin.childDeviceID").
        let child_device_id: String?
    }

    struct ChatActionResponse: Codable, Sendable {
        let type: String
        let command_id: UUID?
        let tier: String?
        let target_display: String?
        let duration_minutes: Int?
        let confirmation_required: Bool?
        let card_id: String?
        let confirmation_reason: String?
        let list_suggestions: [String]?
        let category_guess: String?
        // U1 unlock-disambiguation card fields. Backend sets these when
        // emitting card_id == "U1". `u1_shield_list` is parsed via AnyCodable
        // (an array of dicts) — ChatViewModel unwraps to [U1ShieldEntry].
        let u1_token: String?
        let u1_shield_list: AnyCodable?
    }

    struct ChatResponse: Codable, Sendable {
        let message: String
        let reasoning: String?
        let action: ChatActionResponse?
        let proposals: [ProposalDTO]?
        let receipts: [ReceiptDTO]?
        let cancelledProposals: [String]?

        enum CodingKeys: String, CodingKey {
            case message, reasoning, action, proposals, receipts
            case cancelledProposals = "cancelled_proposals"
        }
    }

    func sendChatMessage(
        message: String,
        childName: String,
        history: [[String: String]],
        forceConfirmations: [String] = []
    ) async throws -> ChatResponse {
        // Read paired family_id from UserDefaults so commands get queued to the child device.
        let familyID = UserDefaults.standard.string(forKey: "evlin.familyID")
        // BigKid child id (set by the BigKid debug panel) — needed for the `reflect` action.
        let bigKidChildID = UserDefaults.standard.string(forKey: "evlin.childDeviceID")

        // Retry up to 3 times — Gemini sometimes returns 500/503.
        var lastStatus = 0
        for attempt in 0..<3 {
            let url = URL(string: "\(baseURL)/parent/chat")!
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.timeoutInterval = 30

            let body = ChatRequest(
                message: message,
                child_name: childName,
                history: history,
                family_id: familyID,
                force_confirmations: forceConfirmations,
                child_device_id: (bigKidChildID?.isEmpty == false) ? bigKidChildID : nil
            )
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

    // MARK: - Family protection mode (DEBUG runtime toggle)

    struct ProtectionModeResponse: Codable {
        let family_id: String
        let mode: String  // "std" | "max"
    }

    func getProtectionMode(familyID: UUID) async throws -> String {
        let url = URL(string: "\(baseURL)/family/\(familyID.uuidString)/protection-mode")!
        var req = URLRequest(url: url)
        req.timeoutInterval = 15
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            throw APIError.serverError((resp as? HTTPURLResponse)?.statusCode ?? 0)
        }
        return try JSONDecoder().decode(ProtectionModeResponse.self, from: data).mode
    }

    func setProtectionMode(familyID: UUID, mode: String) async throws {
        let url = URL(string: "\(baseURL)/family/\(familyID.uuidString)/protection-mode")!
        var req = URLRequest(url: url)
        req.httpMethod = "PUT"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 15
        req.httpBody = try JSONSerialization.data(withJSONObject: ["mode": mode])
        let (_, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            throw APIError.serverError((resp as? HTTPURLResponse)?.statusCode ?? 0)
        }
    }

    // MARK: - BigKid parent reads (same endpoints as `ParentBigKidDebugSheet`)

    func fetchChildStateForParentReview(childDeviceId: UUID) async throws -> ChildStateResponse {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let url = URL(string: trimmed + "/child/state") else {
            throw URLError(.badURL)
        }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.timeoutInterval = 22
        req.setValue(childDeviceId.uuidString, forHTTPHeaderField: "X-Child-Id")
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
            throw APIError.serverError((resp as? HTTPURLResponse)?.statusCode ?? 0)
        }
        return try JSONDecoder.bigKid.decode(ChildStateResponse.self, from: data)
    }

    func approveChildReflectionSubmission(reflectionId: UUID, parentNote: String?) async throws {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let url = URL(string: "\(trimmed)/parent/reflection/\(reflectionId.uuidString)/approve")
        else { throw URLError(.badURL) }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 28
        let note = parentNote?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !note.isEmpty {
            req.httpBody = try JSONSerialization.data(withJSONObject: ["parent_note": note])
        }
        let (_, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
            throw APIError.serverError((resp as? HTTPURLResponse)?.statusCode ?? 0)
        }
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

struct PollTargetDTO: Decodable {
    let bundle_id: String?
    let list_name: String?
    let list_id: String?                 // new: saved list UUID (spec §3.2)
    let has_pending_blob: Bool?
    let category_hint: String?
    let target_all: Bool?                // new: "shield everything"
    let original_request: String
    let target_display: String?
    let target_child_id: String?         // new: which child device (multi-child)
    let force_downgrade: Bool?           // new: parent-confirmed B1 downgrade

    private enum CodingKeys: String, CodingKey {
        case bundle_id
        case list_name
        case list_id
        case has_pending_blob
        case category_hint
        case categoryHint
        case target_all
        case original_request
        case target_display
        case target_child_id
        case force_downgrade
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        bundle_id = try c.decodeIfPresent(String.self, forKey: .bundle_id)
        list_name = try c.decodeIfPresent(String.self, forKey: .list_name)
        list_id = try c.decodeIfPresent(String.self, forKey: .list_id)
        has_pending_blob = try c.decodeIfPresent(Bool.self, forKey: .has_pending_blob)
        category_hint =
            try c.decodeIfPresent(String.self, forKey: .category_hint)
                ?? c.decodeIfPresent(String.self, forKey: .categoryHint)
        target_all = try c.decodeIfPresent(Bool.self, forKey: .target_all)
        original_request = try c.decodeIfPresent(String.self, forKey: .original_request) ?? ""
        target_display = try c.decodeIfPresent(String.self, forKey: .target_display)
        target_child_id = try c.decodeIfPresent(String.self, forKey: .target_child_id)
        force_downgrade = try c.decodeIfPresent(Bool.self, forKey: .force_downgrade)
    }
}

struct PollCommandDTO: Decodable {
    let command_id: UUID
    let action: String
    let tier: String?
    let target: PollTargetDTO
    let duration_minutes: Int?
    let issued_at: String
}

// MARK: - v2 ack-status decode

struct AckPendingConfirmation: Decodable, Sendable {
    let card_id: String
    let context: [String: String]
}

struct AckStatusResponse: Decodable, Sendable {
    let status: String  // "pending" | "confirmed" | "failed" | "timeout" | "pending_confirmation"
    let verb: String?
    let detail: [String: AnyCodable]?
    let displayName: String?
    let category: String?
    let origRequest: String?
    let effectiveState: AckEffectiveState?
    let pendingConfirmation: AckPendingConfirmation?
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

    /// Richer v2 ack-status decoder. See plan Phase 6 Task 6.4.
    func fetchRichAckStatus(commandID: UUID) async throws -> AckStatusResponse {
        var comps = URLComponents(string: "\(baseURL)/parent/ack-status")!
        comps.queryItems = [URLQueryItem(name: "command_id", value: commandID.uuidString)]
        let (data, _) = try await URLSession.shared.data(from: comps.url!)
        return try JSONDecoder().decode(AckStatusResponse.self, from: data)
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
        if container.decodeNil() {
            value = NSNull()
        } else if let int = try? container.decode(Int.self) {
            value = int
        } else if let double = try? container.decode(Double.self) {
            value = double
        } else if let bool = try? container.decode(Bool.self) {
            value = bool
        } else if let string = try? container.decode(String.self) {
            value = string
        } else if let arr = try? container.decode([AnyCodable].self) {
            // Unwrap nested AnyCodable so `as? [Any]` works at call sites.
            value = arr.map { $0.value }
        } else if let dict = try? container.decode([String: AnyCodable].self) {
            value = dict.mapValues { $0.value }
        } else {
            value = ""
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch value {
        case is NSNull:
            try container.encodeNil()
        case let int as Int:
            try container.encode(int)
        case let double as Double:
            try container.encode(double)
        case let bool as Bool:
            try container.encode(bool)
        case let string as String:
            try container.encode(string)
        case let arr as [Any]:
            try container.encode(arr.map { AnyCodable($0) })
        case let dict as [String: Any]:
            try container.encode(dict.mapValues { AnyCodable($0) })
        default:
            try container.encode("")
        }
    }
}
