import Foundation
import Combine

class APIClient: ObservableObject {
    @Published var baseURL: String

    static let defaultURL = "https://evlin-backend.onrender.com/api/v1"

    /// Local dev preset — used by the DEBUG-only Local/Production picker in
    /// HomeSettingsSheet. IP is the Mac's LAN address (`ipconfig getifaddr en0`
    /// on the dev machine). Path keeps `/api/v1` so chat / queue / etc. route
    /// the same as on prod.
    static let localDevURL = "http://localhost:8000/api/v1"

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
        // In DEBUG (simulator/local dev) default to the local backend so the
        // onboarding "Dev sign in" hits localhost:8000 instead of production.
        #if DEBUG
        let fallbackURL = Self.localDevURL
        #else
        let fallbackURL = Self.defaultURL
        #endif
        let raw = baseURL.isEmpty
            ? (useSaved ? saved : fallbackURL)
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
    let artworkURL: URL?
    let tokenAvailable: Bool?
    let appCount: Int?

    enum CodingKeys: String, CodingKey {
        case aliasKey = "alias_key"
        case targetType = "target_type"
        case displayName = "display_name"
        case aliases
        case status
        case bundleID = "bundle_id"
        case artworkURL = "artwork_url"
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
            artworkURL: artworkURL,
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

struct ParentChildDeviceSummaryDTO: Codable, Sendable, Equatable, Identifiable {
    let childDeviceID: UUID
    let displayName: String
    let lastHeartbeat: String?
    let childAuthGranted: Bool
    let buildNumber: Int?
    let catalogAppCount: Int
    let catalogCategoryCount: Int
    let catalogListCount: Int
    let catalogPreview: [String]

    var id: UUID { childDeviceID }
    var shortID: String { String(childDeviceID.uuidString.prefix(8)).lowercased() }

    var catalogSummary: String {
        let appWord = catalogAppCount == 1 ? "app" : "apps"
        let categoryWord = catalogCategoryCount == 1 ? "category" : "categories"
        let listWord = catalogListCount == 1 ? "list" : "lists"
        return "\(catalogAppCount) \(appWord) · \(catalogCategoryCount) \(categoryWord) · \(catalogListCount) \(listWord)"
    }

    var catalogPreviewText: String {
        catalogPreview.isEmpty ? "No catalog entries yet" : catalogPreview.joined(separator: ", ")
    }

    enum CodingKeys: String, CodingKey {
        case childDeviceID = "child_device_id"
        case displayName = "display_name"
        case lastHeartbeat = "last_heartbeat"
        case childAuthGranted = "child_auth_granted"
        case buildNumber = "build_number"
        case catalogAppCount = "catalog_app_count"
        case catalogCategoryCount = "catalog_category_count"
        case catalogListCount = "catalog_list_count"
        case catalogPreview = "catalog_preview"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        childDeviceID = try container.decode(UUID.self, forKey: .childDeviceID)
        displayName = try container.decode(String.self, forKey: .displayName)
        lastHeartbeat = try container.decodeIfPresent(String.self, forKey: .lastHeartbeat)
        childAuthGranted = try container.decodeIfPresent(Bool.self, forKey: .childAuthGranted) ?? false
        buildNumber = try container.decodeIfPresent(Int.self, forKey: .buildNumber)
        catalogAppCount = try container.decodeIfPresent(Int.self, forKey: .catalogAppCount) ?? 0
        catalogCategoryCount = try container.decodeIfPresent(Int.self, forKey: .catalogCategoryCount) ?? 0
        catalogListCount = try container.decodeIfPresent(Int.self, forKey: .catalogListCount) ?? 0
        catalogPreview = try container.decodeIfPresent([String].self, forKey: .catalogPreview) ?? []
    }
}

struct ParentChildDevicesResponseDTO: Codable, Sendable, Equatable {
    let familyID: UUID
    let children: [ParentChildDeviceSummaryDTO]

    enum CodingKeys: String, CodingKey {
        case familyID = "family_id"
        case children
    }
}

struct ParentChildDeviceResponseDTO: Codable, Sendable, Equatable {
    let familyID: UUID
    let child: ParentChildDeviceSummaryDTO

    enum CodingKeys: String, CodingKey {
        case familyID = "family_id"
        case child
    }
}

// MARK: - Lock-setup data flow (Task 10)
//
// The kid-side "Lock setup" surface and the parent picker share one catalog.
// These DTOs and the six APIClient methods below map 1:1 onto REAL backend
// routes (confirmed against app/api/routes/child_device.py + catalog.py):
//
//   fetchLockSetupCatalog     -> GET  /parent/lazy-tag-targets?child_device_id=
//   uploadCapturedAppToken    -> POST /child/app-catalog        (token_kind=app)
//   uploadCapturedCategoryToken -> POST /child/app-catalog      (token_kind=category)
//   createControlList         -> POST /child/catalog-list       (alias_key omitted)
//   updateControlList         -> POST /child/catalog-list       (alias_key set = upsert)
//   confirmFamilyApp          -> POST /parent/app-dictionary/confirm
//
// NOTE (endpoint gap): the backend has no dedicated "update list" route. The
// /child/catalog-list endpoint is an UPSERT keyed by alias_key (see
// upload_child_catalog_list), so updateControlList reuses it with alias_key set
// rather than inventing a PATCH route that does not exist.

/// One target row in the Lock-setup / lazy-tag catalog (token-free, safe for any
/// surface). Mirrors `LazyTagCatalogTarget` semantics; used by `LockSetupCatalog`.
typealias LockSetupTarget = LazyTagCatalogTarget

/// Three-section catalog returned by `GET /parent/lazy-tag-targets`. Sections
/// arrive in fixed order (app, category, list) and each carries `copy` (human
/// section text) plus token-free target rows.
struct LockSetupCatalog: Decodable, Sendable, Equatable {
    let childDeviceID: UUID
    let appTargets: [LockSetupTarget]
    let categoryTargets: [LockSetupTarget]
    let listTargets: [LockSetupTarget]
    let appSectionCopy: String?
    let categorySectionCopy: String?
    let listSectionCopy: String?

    /// All targets flattened in section order — convenient for the parent picker
    /// which renders one `LazyTagCatalogModel.sections(...)` feed.
    var allTargets: [LockSetupTarget] {
        appTargets + categoryTargets + listTargets
    }

    enum CodingKeys: String, CodingKey {
        case childDeviceID = "child_device_id"
        case sections
    }

    // The section element is a tagged union on `type`. Each carries `copy` and a
    // `targets` array whose row shape differs (app/category vs list), so decode
    // each row leniently into a `LockSetupTarget`.
    private struct SectionDTO: Decodable {
        let type: LazyTagCatalogTargetType
        let copy: String?
        let targets: [RowDTO]
    }

    private struct RowDTO: Decodable {
        let aliasKey: UUID
        let targetType: LazyTagCatalogTargetType
        let displayName: String
        let aliases: [String]
        let bundleID: String?
        let bindingKind: String?
        let appCount: Int?
        let artworkURL: URL?

        enum CodingKeys: String, CodingKey {
            case aliasKey = "alias_key"
            case targetType = "target_type"
            case displayName = "display_name"
            case listName = "list_name"
            case aliases
            case bundleID = "bundle_id"
            case bindingKind = "binding_kind"
            case appCount = "app_count"
            case artworkURL = "artwork_url"
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            aliasKey = try c.decode(UUID.self, forKey: .aliasKey)
            targetType = try c.decode(LazyTagCatalogTargetType.self, forKey: .targetType)
            // App/category rows use display_name; list rows use list_name.
            displayName = try c.decodeIfPresent(String.self, forKey: .displayName)
                ?? c.decodeIfPresent(String.self, forKey: .listName)
                ?? ""
            aliases = try c.decodeIfPresent([String].self, forKey: .aliases) ?? []
            bundleID = try c.decodeIfPresent(String.self, forKey: .bundleID)
            bindingKind = try c.decodeIfPresent(String.self, forKey: .bindingKind)
            appCount = try c.decodeIfPresent(Int.self, forKey: .appCount)
            artworkURL = try c.decodeIfPresent(URL.self, forKey: .artworkURL)
        }

        var target: LockSetupTarget {
            LockSetupTarget(
                aliasKey: aliasKey,
                type: targetType,
                displayName: displayName,
                aliases: aliases,
                bundleID: bundleID,
                artworkURL: artworkURL,
                isManual: targetType == .app
                    && (bindingKind?.caseInsensitiveCompare("manual") == .orderedSame
                        || (bundleID?.isEmpty ?? true)),
                memberCount: targetType == .list ? appCount : nil
            )
        }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        childDeviceID = try c.decode(UUID.self, forKey: .childDeviceID)
        let sections = try c.decodeIfPresent([SectionDTO].self, forKey: .sections) ?? []
        func rows(_ type: LazyTagCatalogTargetType) -> [LockSetupTarget] {
            sections.first { $0.type == type }?.targets.map(\.target) ?? []
        }
        func copy(_ type: LazyTagCatalogTargetType) -> String? {
            sections.first { $0.type == type }?.copy
        }
        appTargets = rows(.app)
        categoryTargets = rows(.category)
        listTargets = rows(.list)
        appSectionCopy = copy(.app)
        categorySectionCopy = copy(.category)
        listSectionCopy = copy(.list)
    }
}

/// A captured app token ready to publish to the catalog. Either a verified
/// (Family-Dictionary-confirmed) or manual (bundle-id) binding.
struct CapturedAppToken: Sendable, Equatable {
    let displayName: String
    let bundleID: String?
    let aliases: [String]
    let tokenDataBase64: String?
    /// "verified" once confirmed against the Family Dictionary, else "manual".
    let bindingKind: String

    init(
        displayName: String,
        bundleID: String?,
        aliases: [String] = [],
        tokenDataBase64: String?,
        bindingKind: String = "manual"
    ) {
        self.displayName = displayName
        self.bundleID = bundleID
        self.aliases = aliases
        self.tokenDataBase64 = tokenDataBase64
        self.bindingKind = bindingKind
    }
}

/// A captured Apple-category token ready to publish to the catalog.
struct CapturedCategoryToken: Sendable, Equatable {
    let displayName: String
    /// Canonical semantic key (e.g. "games") plus any extra aliases.
    let aliases: [String]
    let tokenDataBase64: String?

    init(displayName: String, aliases: [String] = [], tokenDataBase64: String?) {
        self.displayName = displayName
        self.aliases = aliases
        self.tokenDataBase64 = tokenDataBase64
    }
}

/// A saved control list — app + category members grouped under one name.
struct ControlListInput: Sendable, Equatable {
    /// Set on update (upsert); nil to create a fresh list.
    let aliasKey: UUID?
    let listName: String
    let aliases: [String]
    let members: [CatalogListMemberUpload]
    /// Optional opaque selection bytes (legacy path). When members are present
    /// the backend derives app_count from them and ignores this.
    let selectionBlobBase64: String?

    init(
        aliasKey: UUID? = nil,
        listName: String,
        aliases: [String] = [],
        members: [CatalogListMemberUpload],
        selectionBlobBase64: String? = nil
    ) {
        self.aliasKey = aliasKey
        self.listName = listName
        self.aliases = aliases
        self.members = members
        self.selectionBlobBase64 = selectionBlobBase64
    }
}

/// Result of a saved control-list upsert.
struct ControlListDTO: Sendable, Equatable {
    let aliasKey: UUID
    let childDeviceID: UUID
    let listName: String
    let aliases: [String]
    let appCount: Int

    init(from response: CatalogListUploadResponse) {
        aliasKey = response.aliasKey
        childDeviceID = response.childDeviceID
        listName = response.listName
        aliases = response.aliases
        appCount = response.appCount
    }
}

/// Parent confirmation that an opaque app token is a specific real app, written
/// to the Family App Dictionary (Task 3). Drives `appTargetIsSaveable`.
struct FamilyAppConfirmation: Sendable, Equatable {
    let familyID: UUID
    let canonicalName: String
    let bundleID: String
    let artworkURL: URL?
    let alias: String?
    /// Provenance, e.g. "catalog", "manual", "parent".
    let source: String

    init(
        familyID: UUID,
        canonicalName: String,
        bundleID: String,
        artworkURL: URL? = nil,
        alias: String? = nil,
        source: String
    ) {
        self.familyID = familyID
        self.canonicalName = canonicalName
        self.bundleID = bundleID
        self.artworkURL = artworkURL
        self.alias = alias
        self.source = source
    }
}

/// A Family App Dictionary entry (response of `POST /parent/app-dictionary/confirm`).
struct FamilyAppDTO: Codable, Sendable, Equatable {
    let id: UUID
    let canonicalName: String
    let bundleID: String
    let artworkURL: URL?
    let aliases: [String]
    let confirmationSource: String
    let confirmationStatus: String

    enum CodingKeys: String, CodingKey {
        case id
        case canonicalName = "canonical_name"
        case bundleID = "bundle_id"
        case artworkURL = "artwork_url"
        case aliases
        case confirmationSource = "confirmation_source"
        case confirmationStatus = "confirmation_status"
    }

    var isConfirmed: Bool {
        confirmationStatus.caseInsensitiveCompare("confirmed") == .orderedSame
    }
}

// MARK: - Plan 4 Profile / Family aggregate DTOs (spec §4.2)
//
// These decode the backend GET /family + GET /me/profile aggregate EXACTLY
// (field names match app/schemas/profile.py snake_case; the Codable property
// names ARE the JSON keys, so no CodingKeys are needed). `AuthAccountDTO` is
// the Plan-1-owned canonical account block (declared later in this file) and
// is REUSED here — it is NOT redeclared. Extra backend keys (e.g. email,
// provider on the account) are ignored by the decoder.

struct AvatarDTO: Codable, Sendable, Equatable {
    let kind: String            // "photo" | "emoji" | "preset"
    let value: String
    let color: String
    let signed_url: String?     // short-lived; only when kind == "photo"
    let expires_at: String?     // ISO-8601 signed_url expiry
}

struct ParentProfileDTO: Codable, Sendable, Equatable {
    let id: String
    let display_name: String
    let avatar: AvatarDTO
}

struct ParentMemberDTO: Codable, Sendable, Equatable, Identifiable {
    let account_id: String
    let display_name: String
    let is_owner: Bool
    let avatar: AvatarDTO
    var id: String { account_id }
}

struct EnrolledDeviceDTO: Codable, Sendable, Equatable, Identifiable {
    let device_id: String
    let mode: String                 // "child" | "parent"
    let label: String?
    let device_model: String?
    let platform: String?
    let os_version: String?
    let display: String?             // composed server-side (§1.7)
    let last_seen_at: String?
    let online: Bool
    let is_self: Bool
    var id: String { device_id }
}

struct ChildDTO: Codable, Sendable, Equatable, Identifiable {
    let id: String
    let display_name: String
    let age: Int?                     // derived from birth_year
    let gender: String?
    let avatar: AvatarDTO
    let devices: [EnrolledDeviceDTO]
}

struct FamilyBlockDTO: Codable, Sendable, Equatable {
    let id: String
    let display_name: String
    let protection_mode: String
    let smart_mode: Bool
    let owner_account_id: String?
    let members: [ParentMemberDTO]
}

struct MeProfileResponseDTO: Codable, Sendable, Equatable {
    let account: AuthAccountDTO      // §15.7 — carries familyID + needsFamily
    let parent_profile: ParentProfileDTO
    let family: FamilyBlockDTO?      // membership read from me.family OR account.familyID (§15.7)
    let children: [ChildDTO]
    let parent_devices: [EnrolledDeviceDTO]
}

struct FamilyDTO: Codable, Sendable, Equatable {
    let family: FamilyBlockDTO
    let children: [ChildDTO]
    let parent_devices: [EnrolledDeviceDTO]
}

// MARK: - Pairing wire DTOs (onboarding v2)
//
// Decode POST /family/pair (PairResponse) + GET /family/pairing-status
// (PairingStatusResponse) EXACTLY as app/api/routes/family.py emits them
// (snake_case property names ARE the JSON keys — no CodingKeys needed).

struct PairResponseDTO: Codable, Sendable, Equatable {
    let family_id: UUID
    let parent_device_id: UUID
    let child_device_id: UUID
    let protection_mode: String
}

struct PairingStatusDTO: Codable, Sendable, Equatable {
    let code: String
    let used: Bool
    let parent_device_id: UUID?
    let child_device_id: UUID?
    let protection_mode: String
}

struct ConsumeInviteResponseDTO: Codable, Sendable, Equatable {
    let family_id: UUID
    let role: String
    let status: String   // "joined" | "pending_approval"
}

// Decode POST /family/create (CreateFamilyResponse) EXACTLY as
// app/api/routes/family.py emits it (snake_case property names ARE the JSON
// keys). `code_expires_at` is intentionally OMITTED here: Swift's strict
// ISO8601 decoder chokes on the backend's fractional-seconds timestamps and the
// kid flow doesn't surface an expiry countdown (mirrors legacy EnterPairingCodeStep).
struct CreateFamilyResponseDTO: Codable, Sendable, Equatable {
    let family_id: UUID
    let child_device_id: UUID
    let pairing_code: String
}

// §15.8 R2 / PIN (B): GET /family/me — the pending co-parent poll path.
struct PendingInviteDTO: Codable, Sendable, Equatable {
    let code: String
    let status: String          // mirrors FamilyInvite.approval_status, e.g. "pending"
}

struct FamilyMeResponseDTO: Codable, Sendable, Equatable {
    let account: AuthAccountDTO          // §15.7 — carries familyID + needsFamily
    let family: FamilyDTO?               // null until owner approval binds family_id
    let pending_invite: PendingInviteDTO?
}

struct AvatarUploadResponseDTO: Codable, Sendable, Equatable {
    let avatar_url: String?
}

extension APIClient {
    /// Child polls for queued commands.
    ///
    /// Plan 8 (§15.3): a terminal `410 family_removed` (the kid's family was
    /// deleted) is surfaced as `APIError.serverError(410)` so the CommandPoller
    /// can FAIL OPEN. All other non-200s stay a quiet `[]` (indistinguishable
    /// from "no commands"), preserving the prior best-effort behavior.
    func pollCommands(deviceID: UUID) async throws -> [PollCommandDTO] {
        var comps = URLComponents(string: "\(baseURL)/child/commands")!
        comps.queryItems = [URLQueryItem(name: "device_id", value: deviceID.uuidString)]
        let (data, response) = try await URLSession.shared.data(from: comps.url!)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 410 { throw APIError.serverError(410) }
        guard status == 200 else { return [] }
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

    func fetchParentChildDevices(familyID: UUID) async throws -> [ParentChildDeviceSummaryDTO] {
        var comps = URLComponents(string: "\(baseURL)/parent/child-devices")!
        comps.queryItems = [URLQueryItem(name: "family_id", value: familyID.uuidString)]
        let (data, resp) = try await URLSession.shared.data(from: comps.url!)
        guard let http = resp as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
            throw APIError.serverError((resp as? HTTPURLResponse)?.statusCode ?? 0)
        }
        return try JSONDecoder().decode(ParentChildDevicesResponseDTO.self, from: data).children
    }

    func fetchParentChildDevice(childDeviceID: UUID) async throws -> ParentChildDeviceResponseDTO {
        let (data, resp) = try await URLSession.shared.data(from: parentChildDeviceURL(childDeviceID: childDeviceID))
        guard let http = resp as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
            throw APIError.serverError((resp as? HTTPURLResponse)?.statusCode ?? 0)
        }
        return try JSONDecoder().decode(ParentChildDeviceResponseDTO.self, from: data)
    }

    func parentChildDeviceURL(childDeviceID: UUID) -> URL {
        URL(string: "\(baseURL)/parent/child-devices/\(childDeviceID.uuidString)")!
    }

    func fetchLazyTagCatalogTargets(
        childDeviceID: UUID,
        query: String? = nil
    ) async throws -> [LazyTagCatalogTarget] {
        let trimmed = query?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let (data, resp) = try await URLSession.shared.data(from: lazyTagTargetsURL(childDeviceID: childDeviceID))
        guard let http = resp as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
            throw APIError.serverError((resp as? HTTPURLResponse)?.statusCode ?? 0)
        }
        let targets = try JSONDecoder().decode(LockSetupCatalog.self, from: data).allTargets
        guard !trimmed.isEmpty else { return targets }
        return targets.filter { $0.matches(searchText: trimmed) }
    }

    func lazyTagTargetsURL(childDeviceID: UUID) -> URL {
        var comps = URLComponents(string: "\(baseURL)/parent/lazy-tag-targets")!
        comps.queryItems = [URLQueryItem(name: "child_device_id", value: childDeviceID.uuidString)]
        return comps.url!
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

    // MARK: - Lock setup (Task 10)

    /// Fetch the three-section Lock-setup catalog (app/category/list) for a kid
    /// device. Token-free — safe for the parent picker. Maps to
    /// `GET /parent/lazy-tag-targets?child_device_id=`.
    func fetchLockSetupCatalog(
        familyID: UUID,
        childDeviceID: UUID
    ) async throws -> LockSetupCatalog {
        // familyID is accepted for call-site symmetry with the other lock-setup
        // methods and future scoping; the backend route keys off child_device_id.
        var comps = URLComponents(string: "\(baseURL)/parent/lazy-tag-targets")!
        comps.queryItems = [URLQueryItem(name: "child_device_id", value: childDeviceID.uuidString)]
        let (data, resp) = try await URLSession.shared.data(from: comps.url!)
        guard let http = resp as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
            throw APIError.serverError((resp as? HTTPURLResponse)?.statusCode ?? 0)
        }
        return try JSONDecoder().decode(LockSetupCatalog.self, from: data)
    }

    /// Publish one captured app token to the catalog. Reuses the existing
    /// `POST /child/app-catalog` upload (token_kind=app). Returns the saved
    /// target with the backend-assigned alias_key.
    ///
    /// IMPORTANT (snapshot semantics): `/child/app-catalog` DELETES any catalog
    /// row absent from the request body. Callers that manage a full local
    /// catalog (e.g. the Lock-setup view) must send the COMPLETE snapshot via
    /// `uploadChildAppCatalog`; this single-target helper is for flows that own
    /// only one row. Prefer the existing capture/sync paths when a full snapshot
    /// is required.
    @discardableResult
    func uploadCapturedAppToken(
        _ app: CapturedAppToken,
        deviceID: UUID
    ) async throws -> LockSetupTarget {
        let upload = ChildAppCatalogUploadApp(
            displayName: app.displayName,
            tokenKind: "app",
            bundleID: app.bundleID,
            aliases: app.aliases,
            tokenAvailable: app.tokenDataBase64?.isEmpty == false,
            tokenDataBase64: app.tokenDataBase64,
            sourceDeviceID: deviceID
        )
        let response = try await uploadChildAppCatalog(deviceID: deviceID, apps: [upload])
        let isManual = app.bindingKind.caseInsensitiveCompare("manual") == .orderedSame
        let row = response.apps.first {
            $0.displayName == app.displayName && ($0.tokenKind.lowercased() != "category")
        } ?? response.apps.first
        guard let row else { throw APIError.serverError(response.count == 0 ? 422 : 500) }
        return LockSetupTarget(
            aliasKey: row.id,
            type: .app,
            displayName: row.displayName,
            aliases: row.aliases,
            bundleID: row.bundleID,
            isManual: isManual || (row.bundleID?.isEmpty ?? true)
        )
    }

    /// Publish one captured Apple-category token to the catalog. Reuses
    /// `POST /child/app-catalog` (token_kind=category). See the snapshot-
    /// semantics caveat on `uploadCapturedAppToken`.
    @discardableResult
    func uploadCapturedCategoryToken(
        _ category: CapturedCategoryToken,
        deviceID: UUID
    ) async throws -> LockSetupTarget {
        let upload = ChildAppCatalogUploadApp(
            displayName: category.displayName,
            tokenKind: "category",
            bundleID: nil,
            aliases: category.aliases,
            tokenAvailable: category.tokenDataBase64?.isEmpty == false,
            tokenDataBase64: category.tokenDataBase64,
            sourceDeviceID: deviceID
        )
        let response = try await uploadChildAppCatalog(deviceID: deviceID, apps: [upload])
        let row = response.apps.first {
            $0.displayName == category.displayName && $0.tokenKind.lowercased() == "category"
        } ?? response.apps.first
        guard let row else { throw APIError.serverError(response.count == 0 ? 422 : 500) }
        return LockSetupTarget(
            aliasKey: row.id,
            type: .category,
            displayName: row.displayName,
            aliases: row.aliases,
            bundleID: nil
        )
    }

    /// Create a new saved control list (app + category members). Maps to
    /// `POST /child/catalog-list` with alias_key omitted.
    @discardableResult
    func createControlList(
        _ list: ControlListInput,
        deviceID: UUID
    ) async throws -> ControlListDTO {
        let response = try await uploadCatalogList(
            deviceID: deviceID,
            aliasKey: nil,
            sourceDeviceID: deviceID,
            listName: list.listName,
            aliases: list.aliases,
            selectionBlobBase64: list.selectionBlobBase64,
            appCount: list.members.count,
            members: list.members
        )
        return ControlListDTO(from: response)
    }

    /// Update an existing saved control list. The backend has NO dedicated
    /// list-update route — `POST /child/catalog-list` is an upsert keyed by
    /// alias_key, so this sends alias_key to update in place. Requires
    /// `list.aliasKey`; throws if absent (would otherwise create a duplicate).
    @discardableResult
    func updateControlList(
        _ list: ControlListInput,
        deviceID: UUID
    ) async throws -> ControlListDTO {
        guard let aliasKey = list.aliasKey else {
            // Defensive: an "update" without an alias_key is a programmer error;
            // do not silently create a second list.
            throw APIError.serverError(400)
        }
        let response = try await uploadCatalogList(
            deviceID: deviceID,
            aliasKey: aliasKey,
            sourceDeviceID: deviceID,
            listName: list.listName,
            aliases: list.aliases,
            selectionBlobBase64: list.selectionBlobBase64,
            appCount: list.members.count,
            members: list.members
        )
        return ControlListDTO(from: response)
    }

    /// Confirm that an opaque app token is a specific real app, written to the
    /// Family App Dictionary. Maps to `POST /parent/app-dictionary/confirm`.
    /// A confirmed entry makes the matching app target saveable in Lock setup.
    @discardableResult
    func confirmFamilyApp(_ confirmation: FamilyAppConfirmation) async throws -> FamilyAppDTO {
        let url = URL(string: "\(baseURL)/parent/app-dictionary/confirm")!
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 22
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        struct Body: Encodable {
            let family_id: UUID
            let canonical_name: String
            let bundle_id: String
            let artwork_url: URL?
            let alias: String?
            let source: String
        }
        req.httpBody = try JSONEncoder().encode(Body(
            family_id: confirmation.familyID,
            canonical_name: confirmation.canonicalName,
            bundle_id: confirmation.bundleID,
            artwork_url: confirmation.artworkURL,
            alias: confirmation.alias,
            source: confirmation.source
        ))
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
            throw APIError.serverError((resp as? HTTPURLResponse)?.statusCode ?? 0)
        }
        return try JSONDecoder().decode(FamilyAppDTO.self, from: data)
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

// MARK: - Plan 4 Profile / Family methods (spec §4.2 / §6.1)
//
// All routes are authed (🔑 get_current_account / 👪 get_current_family on the
// backend). They go through the existing `authedRequest(path:method:)` +
// `authedData(for:)` layer (single-flight 401 refresh, §14.7) — this task does
// NOT add a new interceptor. JSON bodies default to application/json; the
// avatar upload overrides Content-Type with a multipart boundary.

struct UpdateParentProfileBody: Codable {
    var display_name: String?
    var avatar_kind: String?
    var avatar_value: String?
    var avatar_color: String?
}

struct CreateChildBody: Codable {
    var display_name: String
    var birth_year: Int?
    var gender: String?
    var avatar_kind: String = "emoji"
    var avatar_value: String = "🧒"
    var avatar_color: String = "#2E7D32"
    var child_device_id: String?
}

struct UpdateChildBody: Codable {
    var display_name: String?
    var birth_year: Int?
    var gender: String?
    var avatar_kind: String?
    var avatar_value: String?
    var avatar_color: String?
}

extension APIClient {
    /// Runs an authed JSON request through the single-flight-refresh layer and
    /// decodes the response. Throws `APIError.serverError` on a non-2xx status.
    private func authedJSON<T: Decodable>(
        path: String, method: String = "GET", jsonBody: Data? = nil
    ) async throws -> T {
        var req = authedRequest(path: path, method: method)
        if let jsonBody {
            req.httpBody = jsonBody
        }
        let (data, http) = try await authedData(for: req)
        guard (200..<300).contains(http.statusCode) else {
            throw APIError.serverError(http.statusCode)
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    /// GET /me/profile — the authed-account aggregate (account + parent profile
    /// + family + children + parent devices). This is the primary read the
    /// FamilyStore loads. 🔑 get_current_account.
    func fetchMeProfile() async throws -> MeProfileResponseDTO {
        try await authedJSON(path: "/me/profile", method: "GET")
    }

    /// GET /family — the family aggregate (family block + children + parent
    /// devices). 👪 get_current_family; a pending co-parent (familyID == nil)
    /// would 403 here and must use `fetchFamilyMe()` instead.
    func fetchFamily() async throws -> FamilyDTO {
        try await authedJSON(path: "/family", method: "GET")
    }

    /// §15.8 R2 / PIN (B): the PENDING co-parent poll path. A consumed-but-not-
    /// approved co-parent has familyID == nil and CANNOT call `fetchFamily()`
    /// (👪 → 403); it polls THIS 🔑 route until owner approval binds family_id.
    /// Returns family=nil + pending_invite until approved.
    func fetchFamilyMe() async throws -> FamilyMeResponseDTO {
        try await authedJSON(path: "/family/me", method: "GET")
    }

    /// PUT /me/profile — rename + update the parent's emoji/preset avatar.
    func updateParentProfile(_ body: UpdateParentProfileBody) async throws -> ParentProfileDTO {
        let payload = try JSONEncoder().encode(body)
        return try await authedJSON(path: "/me/profile", method: "PUT", jsonBody: payload)
    }

    /// POST /family/children — create a child profile (consent-stamped server-side).
    func createChild(_ body: CreateChildBody) async throws -> ChildDTO {
        let payload = try JSONEncoder().encode(body)
        return try await authedJSON(path: "/family/children", method: "POST", jsonBody: payload)
    }

    /// PUT /family/children/{id}/profile — update a child's name/avatar/etc.
    func updateChild(id: String, _ body: UpdateChildBody) async throws -> ChildDTO {
        let payload = try JSONEncoder().encode(body)
        return try await authedJSON(path: "/family/children/\(id)/profile", method: "PUT", jsonBody: payload)
    }

    /// DELETE /family/children/{id} — archive a child profile.
    func deleteChild(id: String) async throws {
        let req = authedRequest(path: "/family/children/\(id)", method: "DELETE")
        let (_, http) = try await authedData(for: req)
        guard (200..<300).contains(http.statusCode) else {
            throw APIError.serverError(http.statusCode)
        }
    }

    /// PUT /family — rename the family. 👪 get_current_family.
    func renameFamily(displayName: String) async throws -> FamilyDTO {
        let payload = try JSONEncoder().encode(["display_name": displayName])
        return try await authedJSON(path: "/family", method: "PUT", jsonBody: payload)
    }

    // MARK: - Pairing (onboarding v2 — parent PAIRS to the kid family)
    //
    // The KID device calls POST /family/create (mints code + child_device_id);
    // the PARENT (authed) calls POST /family/pair with that code, which BINDS
    // account.family_id (needs_family → false). Unlike the legacy
    // PairingCodeStep (which posted an UNauthed request), the live backend now
    // requires get_current_account on /family/pair — so this goes through the
    // authed layer (Bearer + single-flight 401 refresh, §14.7). Wire shapes
    // match app/api/routes/family.py PairRequest / PairResponse exactly.

    /// POST /family/pair — parent submits the kid's 6-digit code to join the
    /// family. On success the backend binds account.family_id and returns the
    /// bound family + the kid's child_device_id. `protectionMode` is omitted at
    /// onboarding-v2 pair time (the backend keeps the kid's placeholder; the
    /// parent picks Std/Max later) — pass it only from a re-pair/Settings flow.
    @discardableResult
    func pairFamily(
        code: String,
        deviceLabel: String,
        protectionMode: String? = nil
    ) async throws -> PairResponseDTO {
        var body: [String: Any] = [
            "code": code,
            "parent_device_label": deviceLabel,
        ]
        if let protectionMode { body["protection_mode"] = protectionMode }
        let payload = try JSONSerialization.data(withJSONObject: body)
        return try await authedJSON(path: "/family/pair", method: "POST", jsonBody: payload)
    }

    /// GET /family/pairing-status?code= — read the live state of a pairing
    /// code. UNauthenticated on the backend (the kid polls it while showing the
    /// code; the parent can also read it to confirm a code is still valid).
    func fetchPairingStatus(code: String) async throws -> PairingStatusDTO {
        var comps = URLComponents(string: "\(baseURL)/family/pairing-status")!
        comps.queryItems = [URLQueryItem(name: "code", value: code)]
        let (data, resp) = try await URLSession.shared.data(from: comps.url!)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw APIError.serverError((resp as? HTTPURLResponse)?.statusCode ?? 0)
        }
        return try JSONDecoder().decode(PairingStatusDTO.self, from: data)
    }

    /// POST /family/invite/consume — a parent joins an EXISTING family by
    /// entering a co-parent invite code (distinct from the kid pairing code).
    /// Authed (get_current_account). With owner-approval ON the backend returns
    /// status "pending_approval" and does NOT yet bind account.family_id — the
    /// owner approves before the family appears. Wire shape matches
    /// app/api/routes/family.py ConsumeInviteRequest / ConsumeInviteResponse.
    @discardableResult
    func consumeCoParentInvite(code: String) async throws -> ConsumeInviteResponseDTO {
        let payload = try JSONSerialization.data(withJSONObject: ["code": code])
        return try await authedJSON(path: "/family/invite/consume", method: "POST", jsonBody: payload)
    }

    // MARK: - Pairing (onboarding v2 — KID creates the family)
    //
    // The KID device is UNAUTHENTICATED (no parent account on it), so these go
    // over a bare URLSession — NOT the authed Bearer layer used by /family/pair.
    // Wire shapes match app/api/routes/family.py CreateFamilyRequest /
    // CreateFamilyResponse + GrantAuthRequest exactly. This replaces the inline
    // raw-URLSession blocks the legacy EnterPairingCodeStep / GrantPermissionStep
    // carried, centralizing them on APIClient (same endpoints, same payloads).

    /// POST /family/create — the kid device mints a family + child device + a
    /// 6-digit pairing code to show the parent. `protectionMode` is a placeholder
    /// ("std") the parent overrides at /family/pair time. Device hardware fields
    /// (§1.7) are reported from `DeviceInfoProvider`.
    @discardableResult
    func createFamily(
        childDeviceLabel: String,
        protectionMode: String = "std"
    ) async throws -> CreateFamilyResponseDTO {
        let url = URL(string: "\(baseURL)/family/create")!
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 15
        let info = DeviceInfoProvider.current()
        let body: [String: Any] = [
            "child_device_label": childDeviceLabel,
            "protection_mode": protectionMode,
            "device_model": info.device_model,
            "device_model_id": info.device_model_id,
            "platform": info.platform,
            "os_version": info.os_version,
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw APIError.serverError((resp as? HTTPURLResponse)?.statusCode ?? 0)
        }
        return try JSONDecoder().decode(CreateFamilyResponseDTO.self, from: data)
    }

    /// POST /family/auth-status/grant — the kid device reports that the on-device
    /// Family Controls (Screen Time) authorization succeeded, so the parent's
    /// Max-mode WaitForAuth poll can proceed. UNauthenticated (kid device); the
    /// backend guards on child-device presence/ownership.
    func grantChildAuthStatus(childDeviceID: UUID) async throws {
        let url = URL(string: "\(baseURL)/family/auth-status/grant")!
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 15
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "child_device_id": childDeviceID.uuidString,
        ])
        let (_, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw APIError.serverError((resp as? HTTPURLResponse)?.statusCode ?? 0)
        }
    }

    /// Multipart upload of a parent avatar photo. Returns the fresh signed URL.
    func uploadParentAvatar(jpegData: Data) async throws -> String? {
        try await uploadAvatar(path: "/me/avatar", jpegData: jpegData)
    }

    /// Multipart upload of a child avatar photo. Returns the fresh signed URL.
    func uploadChildAvatar(childId: String, jpegData: Data) async throws -> String? {
        try await uploadAvatar(path: "/family/children/\(childId)/avatar", jpegData: jpegData)
    }

    private func uploadAvatar(path: String, jpegData: Data) async throws -> String? {
        let boundary = "evlin-\(UUID().uuidString)"
        var body = Data()
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"avatar.jpg\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: image/jpeg\r\n\r\n".data(using: .utf8)!)
        body.append(jpegData)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)

        var req = authedRequest(path: path, method: "POST")
        // Override the default application/json the authed builder sets — the
        // multipart Content-Type MUST carry the boundary or the backend can't
        // parse the form-data part.
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.httpBody = body

        let (data, http) = try await authedData(for: req)
        guard (200..<300).contains(http.statusCode) else {
            throw APIError.serverError(http.statusCode)
        }
        return try JSONDecoder().decode(AvatarUploadResponseDTO.self, from: data).avatar_url
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

// MARK: - Single-flight 401 refresh (§14.7)

/// Coalesces concurrent token refreshes into ONE in-flight task. All callers
/// that hit a 401 await the SAME refresh; the underlying /auth/refresh rotates
/// the token exactly once (rotation + reuse-detection on the backend would 401
/// a second concurrent refresh, spuriously signing the user out mid-onboarding).
actor SingleFlightRefresher {
    private var inFlight: Task<String, Error>?
    private let performRefresh: () async throws -> String

    init(performRefresh: @escaping () async throws -> String) {
        self.performRefresh = performRefresh
    }

    /// Returns a fresh access token, sharing any in-flight refresh.
    func refreshedToken() async throws -> String {
        if let task = inFlight {
            return try await task.value
        }
        let task = Task { try await performRefresh() }
        inFlight = task
        defer { inFlight = nil }
        return try await task.value
    }
}

/// Signed-out signal — APIClient publishes this when refresh fails terminally.
extension Notification.Name {
    static let evlinSessionSignedOut = Notification.Name("evlin.session.signedOut")
}

extension APIClient {
    enum AuthError: Error, Equatable {
        case signedOut
        case http(Int)
    }

    /// Builds an authed URLRequest with the current access token. Callers that
    /// receive a 401 should call `refreshAndRetry` exactly once.
    func authedRequest(path: String, method: String = "GET") -> URLRequest {
        let url = URL(string: "\(baseURL)\(path)")!
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let access = KeychainStore.shared.load()?.accessToken {
            req.setValue("Bearer \(access)", forHTTPHeaderField: "Authorization")
        }
        return req
    }

    /// Performs an authed request, transparently refreshing on a single 401 and
    /// retrying exactly once. On refresh failure, publishes `.evlinSessionSignedOut`.
    func authedData(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, resp) = try await URLSession.shared.data(for: request)
        guard let http = resp as? HTTPURLResponse else { throw AuthError.http(-1) }
        if http.statusCode != 401 { return (data, http) }

        // Single 401 → single-flight refresh → retry once.
        do {
            let newAccess = try await Self.sharedRefresher.refreshedToken()
            var retry = request
            retry.setValue("Bearer \(newAccess)", forHTTPHeaderField: "Authorization")
            let (data2, resp2) = try await URLSession.shared.data(for: retry)
            guard let http2 = resp2 as? HTTPURLResponse else { throw AuthError.http(-1) }
            return (data2, http2)
        } catch {
            KeychainStore.shared.clear()
            NotificationCenter.default.post(name: .evlinSessionSignedOut, object: nil)
            throw AuthError.signedOut
        }
    }

    /// The process-wide single-flight refresher. Its work closure calls
    /// POST /auth/refresh with the stored refresh token and atomically rewrites
    /// the Keychain with the rotated tokens (§14.7).
    static let sharedRefresher = SingleFlightRefresher {
        guard let current = KeychainStore.shared.load() else {
            throw APIClient.AuthError.signedOut
        }
        let base = APIClient().baseURL
        let url = URL(string: "\(base)/auth/refresh")!
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(["refresh_token": current.refreshToken])
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            throw APIClient.AuthError.signedOut
        }
        let decoded = try JSONDecoder().decode(AuthResultDTO.self, from: data)
        // Atomic Keychain rewrite with the rotated pair, preserving the full
        // account (§15.7): familyID + displayName are NOT dropped on refresh.
        // `decoded.account` is the Codable AuthAccountDTO (UUID-typed); persist
        // its fields as strings in the StoredTokens blob.
        let acct = decoded.account
        try KeychainStore.shared.save(StoredTokens(
            accessToken: decoded.access_token,
            refreshToken: decoded.refresh_token,
            accountID: acct.id.uuidString,
            familyID: acct.familyID?.uuidString,
            displayName: acct.displayName,
            needsFamily: acct.needsFamily,
        ))
        return decoded.access_token
    }
}

// MARK: - Auth wire DTOs (§4.1 AuthResult — snake_case, as the backend sends)

/// Canonical, public auth-account shape (§15.7 / §15.8 PIN A). camelCase +
/// UUID-typed, and `Codable` so it decodes DIRECTLY via JSONDecoder — there is
/// NO non-Codable wire variant for the account object. `needsFamily` decodes
/// from `needs_family` INSIDE the account object (NOT a separate top-level
/// field). It carries BOTH `familyID` and `displayName` (the auth response does
/// NOT discard them).
///
/// NOTE (cross-task seam, Task 11 owner): the §15.7 contract defines this type
/// as "owned by" `AuthService.swift` (Task 11). Task 10's `AuthResultDTO.account`
/// + single-flight `sharedRefresher` consume it, so it is declared here to keep
/// Task 10 self-compiling. When Task 11 lands it reuses this EXACT type (move it
/// to AuthService.swift then, do NOT redeclare it).
struct AuthAccountDTO: Codable, Sendable, Equatable {
    let id: UUID
    let familyID: UUID?
    let displayName: String?
    let needsFamily: Bool
    enum CodingKeys: String, CodingKey {
        case id
        case familyID = "family_id"
        case displayName = "display_name"
        case needsFamily = "needs_family"
    }
}

/// The `/auth/*` `AuthResult` envelope. This raw struct carries only the TOKEN
/// fields (§15.7 / §15.8 PIN A allows a raw token struct). The `account` object
/// is the canonical `Codable` `AuthAccountDTO` and decodes DIRECTLY here — there
/// is NO separate non-Codable `AuthAccountWireDTO`. `needs_family` lives INSIDE
/// `account` (see `AuthAccountDTO`); the backend also echoes a top-level
/// `needs_family` on the envelope for convenience, decoded below but never the
/// source of truth (read `account.needsFamily`).
struct AuthResultDTO: Codable, Sendable {
    let access_token: String
    let refresh_token: String
    let expires_in: Int
    let account: AuthAccountDTO
    let is_new_account: Bool
    let needs_family: Bool
}
