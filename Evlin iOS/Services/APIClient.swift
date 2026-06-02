import Foundation
import Combine

class APIClient: ObservableObject {
    @Published var baseURL: String

    static let defaultURL = "https://evlin-backend.onrender.com/api/v1"

    /// Local dev preset — used by the DEBUG-only Local/Production picker in
    /// HomeSettingsSheet. IP is the Mac's LAN address (`ipconfig getifaddr en0`
    /// on the dev machine). Path keeps `/api/v1` so chat / queue / etc. route
    /// the same as on prod.
    static let localDevURL = "http://192.168.1.175:8000/api/v1"

    /// One-shot migration: 2026-05-07 backend split moved the Evlin Backend
    /// from the old `adaptive-engine` Railway service to its own Render
    /// service. Existing users have the old URL persisted in UserDefaults
    /// and won't see the new default unless we rewrite the saved value.
    /// Substring match — catches trailing-slash, mixed-scheme, or any
    /// variant a parent might have typed. Only the first launch after
    /// upgrade hits this branch.
    private static let legacyHostFragments: [String] = [
        "adaptive-engine-production.up.railway.app",
        // Any other railway service we previously pointed parents at.
    ]

    init(baseURL: String = "") {
        var saved = UserDefaults.standard.string(forKey: "serverURL") ?? ""
        if Self.legacyHostFragments.contains(where: { saved.contains($0) }) {
            saved = Self.defaultURL
            UserDefaults.standard.set(saved, forKey: "serverURL")
        }
        // Previously this code rejected any saved URL containing "192.168"
        // or "localhost", forcing dev builds back to the Render default every
        // launch — annoying when iterating against a local backend. Trust
        // whatever the user explicitly saved. The DEBUG-only picker in
        // HomeSettingsSheet still gives one-tap revert to production.
        let useSaved = !saved.isEmpty
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
        // Plan-arch: parent-side LocalAliasStore snapshot so the validator can
        // avoid lazy_tag cards for apps/categories already known on this device.
        let client_alias_state: [String: [String]]?
        // When true the backend skips its deterministic fastpath router and
        // sends the same message straight to strategy_agent. Used by the
        // "This isn't what I meant" button below confirm cards so the parent
        // can ask the AI to re-interpret a turn the fastpath got wrong.
        // Default false → normal fastpath-first flow.
        let skip_fastpath: Bool
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
        let queuedCommands: [PlanPatchQueuedCommand]?
        // True when the deterministic fastpath router produced this
        // response. False when the request fell through to strategy_agent.
        // Drives whether ChatView shows the "This isn't what I meant"
        // button — on AI-emitted cards, re-tapping reinterpret would just
        // send the same message back to the same AI, which is useless.
        // Defaults false for back-compat with older backends that don't
        // set the field.
        let viaFastpath: Bool?

        enum CodingKeys: String, CodingKey {
            case message, reasoning, action, proposals, receipts
            case queuedCommands = "queued_commands"
            case cancelledProposals = "cancelled_proposals"
            case viaFastpath = "via_fastpath"
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
                child_device_id: (bigKidChildID?.isEmpty == false) ? bigKidChildID : nil,
                client_alias_state: [
                    "known_apps": LocalAliasStore.shared.allApplicationKeys(),
                    "known_categories": LocalAliasStore.shared.allCategoryNames()
                ],
                // Legacy APIClient.chat() path always lets the backend fastpath
                // attempt to handle the message — the reinterpret flow goes
                // through ChatViewModel.sendChatMessageWithRawData(), which
                // sets skip_fastpath=true explicitly.
                skip_fastpath: false
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

    /// Parent-only fetch of a reflection's full content including each
    /// quiz question's correct-answer index. The kid `/child/state`
    /// endpoint strips correctIndex; this `/parent/reflection/{rid}`
    /// endpoint returns it for the parent-review surfaces.
    func fetchReflectionForParent(reflectionId: UUID) async throws -> ReflectionRequestForParent {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let url = URL(string: "\(trimmed)/parent/reflection/\(reflectionId.uuidString)") else {
            throw URLError(.badURL)
        }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.timeoutInterval = 22
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
            throw APIError.serverError((resp as? HTTPURLResponse)?.statusCode ?? 0)
        }
        return try JSONDecoder.bigKid.decode(ReflectionRequestForParent.self, from: data)
    }

    /// Parent sends the reflection back for a rework. Mirrors
    /// `POST /parent/reflection/{rid}/request-redo`. The kid lock
    /// screen will surface `redoNote` (in quotes) and flip the entry
    /// CTA from "Start reflection" to "Rework Essay" once the next
    /// kid-state poll lands.
    func requestRedoChildReflection(reflectionId: UUID, redoNote: String?) async throws {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let url = URL(string: "\(trimmed)/parent/reflection/\(reflectionId.uuidString)/request-redo") else {
            throw URLError(.badURL)
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 22
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = ["redo_note": redoNote as Any]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (_, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
            throw APIError.serverError((resp as? HTTPURLResponse)?.statusCode ?? 0)
        }
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

    /// Parent cancels an active reflection — wipes the request on the
    /// backend so the next kid-state poll returns no reflection. Used
    /// by the Profile reflection sub-tab's "Cancel reflection" alert.
    /// Idempotent — server returns 204 even if the rid is already gone.
    func cancelChildReflection(reflectionId: UUID) async throws {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let url = URL(string: "\(trimmed)/parent/reflection/\(reflectionId.uuidString)")
        else { throw URLError(.badURL) }
        var req = URLRequest(url: url)
        req.httpMethod = "DELETE"
        req.timeoutInterval = 22
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
    let catalog_token_data_base64: String?
    let catalog_category_token_data_base64: String?
    let applications: [String]?
    let applicationCategories: [String]?

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
        case scope
        case applications
        case applicationCategories
        case application_categories
        case canonicalCatalogTokenDataBase64 = "catalog_token_data_base64"
        case canonicalCatalogCategoryTokenDataBase64 = "catalog_category_token_data_base64"
        case legacyTokenDataBase64 = "token_data_base64"
        case legacyCategoryTokenDataBase64 = "category_token_data_base64"
        case camelCatalogTokenDataBase64 = "catalogTokenDataBase64"
        case camelCatalogCategoryTokenDataBase64 = "catalogCategoryTokenDataBase64"
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
        catalog_token_data_base64 =
            try c.decodeIfPresent(String.self, forKey: .canonicalCatalogTokenDataBase64)
                ?? c.decodeIfPresent(String.self, forKey: .legacyTokenDataBase64)
                ?? c.decodeIfPresent(String.self, forKey: .camelCatalogTokenDataBase64)
        catalog_category_token_data_base64 =
            try c.decodeIfPresent(String.self, forKey: .canonicalCatalogCategoryTokenDataBase64)
                ?? c.decodeIfPresent(String.self, forKey: .legacyCategoryTokenDataBase64)
                ?? c.decodeIfPresent(String.self, forKey: .camelCatalogCategoryTokenDataBase64)
        applications = try c.decodeIfPresent([String].self, forKey: .applications)
        applicationCategories =
            try c.decodeIfPresent([String].self, forKey: .applicationCategories)
                ?? c.decodeIfPresent([String].self, forKey: .application_categories)
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

// MARK: - Child app catalog capture APIs

struct ChildAppCatalogUploadApp: Codable, Sendable, Equatable {
    let aliasKey: UUID?
    let displayName: String
    let tokenKind: String
    let bundleID: String?
    let aliases: [String]
    let tokenAvailable: Bool
    let tokenDataBase64: String?
    let sourceDeviceID: UUID?

    init(
        aliasKey: UUID? = nil,
        displayName: String,
        tokenKind: String = "app",
        bundleID: String? = nil,
        aliases: [String] = [],
        tokenAvailable: Bool = true,
        tokenDataBase64: String? = nil,
        sourceDeviceID: UUID? = nil
    ) {
        self.aliasKey = aliasKey
        self.displayName = displayName
        self.tokenKind = tokenKind
        self.bundleID = bundleID
        self.aliases = aliases
        self.tokenAvailable = tokenAvailable
        self.tokenDataBase64 = tokenDataBase64
        self.sourceDeviceID = sourceDeviceID
    }

    enum CodingKeys: String, CodingKey {
        case aliasKey = "alias_key"
        case displayName = "display_name"
        case tokenKind = "token_kind"
        case bundleID = "bundle_id"
        case aliases
        case tokenAvailable = "token_available"
        case tokenDataBase64 = "token_data_base64"
        case sourceDeviceID = "source_device_id"
    }
}

struct ChildAppCatalogEntryResponse: Codable, Sendable, Equatable {
    let id: UUID
    let displayName: String
    let tokenKind: String
    let bundleID: String?
    let aliases: [String]
    let tokenAvailable: Bool
    let tokenDataBase64: String?
    let updatedAt: String?

    enum CodingKeys: String, CodingKey {
        case id
        case displayName = "display_name"
        case tokenKind = "token_kind"
        case bundleID = "bundle_id"
        case aliases
        case tokenAvailable = "token_available"
        case tokenDataBase64 = "token_data_base64"
        case updatedAt = "updated_at"
    }
}

struct ChildAppCatalogUploadResponse: Codable, Sendable, Equatable {
    let childDeviceID: UUID
    let count: Int
    let apps: [ChildAppCatalogEntryResponse]

    enum CodingKeys: String, CodingKey {
        case childDeviceID = "child_device_id"
        case count
        case apps
    }
}

struct CatalogSearchResultDTO: Codable, Sendable, Equatable {
    let canonicalName: String
    let bundleID: String?
    let aliases: [String]
    let artworkURL: URL?

    enum CodingKeys: String, CodingKey {
        case canonicalName = "canonical_name"
        case bundleID = "bundle_id"
        case aliases
        case artworkURL = "artwork_url"
    }

    var result: CatalogSearchResult {
        CatalogSearchResult(
            canonicalName: canonicalName,
            bundleID: bundleID,
            aliases: aliases,
            artworkURL: artworkURL
        )
    }
}

struct CatalogSearchResponseDTO: Codable, Sendable, Equatable {
    let results: [CatalogSearchResultDTO]
}

struct CatalogListUploadResponse: Codable, Sendable, Equatable {
    let aliasKey: UUID
    let childDeviceID: UUID
    let listName: String
    let aliases: [String]
    let appCount: Int

    enum CodingKeys: String, CodingKey {
        case aliasKey = "alias_key"
        case childDeviceID = "child_device_id"
        case listName = "list_name"
        case aliases
        case appCount = "app_count"
    }
}

enum CatalogListMemberTargetType: String, Codable, Sendable, Equatable {
    case app
    case category
}

struct CatalogListMemberUpload: Codable, Sendable, Equatable {
    let targetType: CatalogListMemberTargetType
    let aliasKey: UUID

    enum CodingKeys: String, CodingKey {
        case targetType = "target_type"
        case aliasKey = "alias_key"
    }
}

struct CatalogListUploadRequestBody: Codable, Sendable, Equatable {
    let deviceID: UUID
    let aliasKey: UUID?
    let sourceDeviceID: UUID?
    let listName: String
    let aliases: [String]
    let selectionBlobBase64: String?
    let appCount: Int
    let members: [CatalogListMemberUpload]?

    enum CodingKeys: String, CodingKey {
        case deviceID = "device_id"
        case aliasKey = "alias_key"
        case sourceDeviceID = "source_device_id"
        case listName = "list_name"
        case aliases
        case selectionBlobBase64 = "selection_blob_base64"
        case appCount = "app_count"
        case members
    }
}

struct ParentLazyTagCatalogResponse: Codable, Sendable, Equatable {
    let childDeviceID: UUID
    let apps: [ParentLazyTagAppProjection]
    let categories: [ParentLazyTagAppProjection]
    let lists: [ParentLazyTagListProjection]

    enum CodingKeys: String, CodingKey {
        case childDeviceID = "child_device_id"
        case apps
        case categories
        case lists
    }

    var lazyTagTargets: [LazyTagCatalogTarget] {
        var seen = Set<UUID>()
        func appendUnique(_ target: LazyTagCatalogTarget, into out: inout [LazyTagCatalogTarget]) {
            guard seen.insert(target.aliasKey).inserted else { return }
            out.append(target)
        }

        var out: [LazyTagCatalogTarget] = []
        for row in apps where row.targetType == .app {
            appendUnique(row.lazyTagTarget, into: &out)
        }
        for row in categories where row.targetType == .category {
            appendUnique(row.lazyTagTarget, into: &out)
        }
        for row in lists {
            appendUnique(row.lazyTagTarget, into: &out)
        }
        return out
    }
}

struct ParentLazyTagAppProjection: Codable, Sendable, Equatable {
    let aliasKey: UUID
    let targetType: LazyTagCatalogTargetType
    let displayName: String
    let bindingKind: String
    let bundleID: String?
    let aliases: [String]
    let tokenAvailable: Bool
    let status: String
    let artworkURL: URL?

    enum CodingKeys: String, CodingKey {
        case aliasKey = "alias_key"
        case targetType = "target_type"
        case displayName = "display_name"
        case bindingKind = "binding_kind"
        case bundleID = "bundle_id"
        case aliases
        case tokenAvailable = "token_available"
        case status
        case artworkURL = "artwork_url"
    }

    var lazyTagTarget: LazyTagCatalogTarget {
        LazyTagCatalogTarget(
            aliasKey: aliasKey,
            type: targetType,
            displayName: displayName,
            aliases: aliases,
            bundleID: bundleID,
            artworkURL: artworkURL,
            isManual: bindingKind.caseInsensitiveCompare("manual") == .orderedSame
        )
    }
}

struct ParentLazyTagListProjection: Codable, Sendable, Equatable {
    let aliasKey: UUID
    let targetType: LazyTagCatalogTargetType
    let listName: String
    let aliases: [String]
    let appCount: Int
    let status: String

    enum CodingKeys: String, CodingKey {
        case aliasKey = "alias_key"
        case targetType = "target_type"
        case listName = "list_name"
        case aliases
        case appCount = "app_count"
        case status
    }

    var lazyTagTarget: LazyTagCatalogTarget {
        LazyTagCatalogTarget(
            aliasKey: aliasKey,
            type: .list,
            displayName: listName,
            aliases: aliases,
            memberCount: appCount
        )
    }
}

struct LazyTagAliasTargetResponse: Codable, Sendable, Equatable {
    let aliasKey: UUID
    let targetType: LazyTagCatalogTargetType
    let displayName: String
    let aliases: [String]
    let status: String
    let bundleID: String?
    let tokenAvailable: Bool?
    let appCount: Int?

    enum CodingKeys: String, CodingKey {
        case aliasKey = "alias_key"
        case targetType = "target_type"
        case displayName = "display_name"
        case aliases
        case status
        case bundleID = "bundle_id"
        case tokenAvailable = "token_available"
        case appCount = "app_count"
    }

    var lazyTagTarget: LazyTagCatalogTarget {
        LazyTagCatalogTarget(
            aliasKey: aliasKey,
            type: targetType,
            displayName: displayName,
            aliases: aliases,
            bundleID: bundleID,
            isManual: targetType == .app && (bundleID?.isEmpty ?? true),
            memberCount: appCount
        )
    }
}

struct LazyTagAliasMutationRequest: Codable, Sendable, Equatable {
    let familyID: UUID
    let childDeviceID: UUID
    let targetType: LazyTagCatalogTargetType
    let alias: String

    enum CodingKeys: String, CodingKey {
        case familyID = "family_id"
        case childDeviceID = "child_device_id"
        case targetType = "target_type"
        case alias
    }
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

    /// Child uploads its APNs device token so the backend can send a
    /// `content-available:1` silent push when a command is queued (Phase 5
    /// L2 delivery). Idempotent on the backend — safe to call on every
    /// `didRegisterForRemoteNotificationsWithDeviceToken`.
    func registerAPNsToken(deviceID: UUID, token: String) async throws {
        let url = URL(string: "\(baseURL)/child/register-apns")!
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(["device_id": deviceID.uuidString, "apns_token": token])
        let (_, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
            throw APIError.serverError((resp as? HTTPURLResponse)?.statusCode ?? 0)
        }
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

    @discardableResult
    func uploadChildAppCatalog(
        deviceID: UUID,
        apps: [ChildAppCatalogUploadApp]
    ) async throws -> ChildAppCatalogUploadResponse {
        let url = URL(string: "\(baseURL)/child/app-catalog")!
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 22
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        struct Body: Codable {
            let deviceID: UUID
            let apps: [ChildAppCatalogUploadApp]

            enum CodingKeys: String, CodingKey {
                case deviceID = "device_id"
                case apps
            }
        }
        req.httpBody = try JSONEncoder().encode(Body(deviceID: deviceID, apps: apps))
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
            throw APIError.serverError((resp as? HTTPURLResponse)?.statusCode ?? 0)
        }
        return try JSONDecoder().decode(ChildAppCatalogUploadResponse.self, from: data)
    }

    func catalogSearch(q: String) async throws -> [CatalogSearchResultDTO] {
        var comps = URLComponents(string: "\(baseURL)/catalog/search")!
        comps.queryItems = [URLQueryItem(name: "q", value: q)]
        let (data, resp) = try await URLSession.shared.data(from: comps.url!)
        guard let http = resp as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
            throw APIError.serverError((resp as? HTTPURLResponse)?.statusCode ?? 0)
        }
        return try JSONDecoder().decode(CatalogSearchResponseDTO.self, from: data).results
    }

    func fetchLazyTagCatalogTargets(
        childDeviceID: UUID,
        query: String? = nil
    ) async throws -> [LazyTagCatalogTarget] {
        var comps = URLComponents(string: "\(baseURL)/parent/child-app-catalog")!
        comps.queryItems = [URLQueryItem(name: "child_device_id", value: childDeviceID.uuidString)]
        let trimmed = query?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let (data, resp) = try await URLSession.shared.data(from: comps.url!)
        guard let http = resp as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
            throw APIError.serverError((resp as? HTTPURLResponse)?.statusCode ?? 0)
        }
        let targets = try JSONDecoder().decode(ParentLazyTagCatalogResponse.self, from: data).lazyTagTargets
        guard !trimmed.isEmpty else { return targets }
        return targets.filter { $0.matches(searchText: trimmed) }
    }

    @discardableResult
    func saveLazyTagAlias(
        familyID: UUID,
        childDeviceID: UUID,
        target: LazyTagCatalogTarget,
        alias: String
    ) async throws -> LazyTagCatalogTarget {
        let url = URL(string: "\(baseURL)/parent/child-app-catalog/\(target.aliasKey.uuidString)/aliases")!
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 22
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(LazyTagAliasMutationRequest(
            familyID: familyID,
            childDeviceID: childDeviceID,
            targetType: target.type,
            alias: alias
        ))
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
            throw APIError.serverError((resp as? HTTPURLResponse)?.statusCode ?? 0)
        }
        return try JSONDecoder().decode(LazyTagAliasTargetResponse.self, from: data).lazyTagTarget
    }

    @discardableResult
    func removeLazyTagAlias(
        familyID: UUID,
        childDeviceID: UUID,
        target: LazyTagCatalogTarget,
        alias: String
    ) async throws -> LazyTagCatalogTarget {
        var comps = URLComponents(
            string: "\(baseURL)/parent/child-app-catalog/\(target.aliasKey.uuidString)/aliases/\(Self.pathComponent(alias))"
        )!
        comps.queryItems = [
            URLQueryItem(name: "family_id", value: familyID.uuidString),
            URLQueryItem(name: "child_device_id", value: childDeviceID.uuidString),
            URLQueryItem(name: "target_type", value: target.type.rawValue),
        ]
        var req = URLRequest(url: comps.url!)
        req.httpMethod = "DELETE"
        req.timeoutInterval = 22
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
            throw APIError.serverError((resp as? HTTPURLResponse)?.statusCode ?? 0)
        }
        return try JSONDecoder().decode(LazyTagAliasTargetResponse.self, from: data).lazyTagTarget
    }

    @discardableResult
    func renameLazyTagAlias(
        familyID: UUID,
        childDeviceID: UUID,
        target: LazyTagCatalogTarget,
        oldAlias: String,
        newAlias: String
    ) async throws -> LazyTagCatalogTarget {
        let url = URL(
            string: "\(baseURL)/parent/child-app-catalog/\(target.aliasKey.uuidString)/aliases/\(Self.pathComponent(oldAlias))"
        )!
        var req = URLRequest(url: url)
        req.httpMethod = "PATCH"
        req.timeoutInterval = 22
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(LazyTagAliasMutationRequest(
            familyID: familyID,
            childDeviceID: childDeviceID,
            targetType: target.type,
            alias: newAlias
        ))
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
            throw APIError.serverError((resp as? HTTPURLResponse)?.statusCode ?? 0)
        }
        return try JSONDecoder().decode(LazyTagAliasTargetResponse.self, from: data).lazyTagTarget
    }

    private static func pathComponent(_ value: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/?#[]@!$&'()*+,;=")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    @discardableResult
    func uploadCatalogList(
        deviceID: UUID,
        aliasKey: UUID? = nil,
        sourceDeviceID: UUID? = nil,
        listName: String,
        aliases: [String],
        selectionBlobBase64: String? = nil,
        appCount: Int,
        members: [CatalogListMemberUpload]? = nil
    ) async throws -> CatalogListUploadResponse {
        let url = URL(string: "\(baseURL)/child/catalog-list")!
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 22
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(
            CatalogListUploadRequestBody(
                deviceID: deviceID,
                aliasKey: aliasKey,
                sourceDeviceID: sourceDeviceID,
                listName: listName,
                aliases: aliases,
                selectionBlobBase64: selectionBlobBase64,
                appCount: appCount,
                members: members
            )
        )
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
            throw APIError.serverError((resp as? HTTPURLResponse)?.statusCode ?? 0)
        }
        return try JSONDecoder().decode(CatalogListUploadResponse.self, from: data)
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
