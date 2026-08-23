import Foundation
import Combine

class APIClient: ObservableObject {
    @Published var baseURL: String

    static let defaultURL = "https://evlin-backend.onrender.com/api/v1"

    /// The baseURL of the most-recently configured live `APIClient` — set at the
    /// END of `init` and by `saveServerURL`. The process-wide `sharedRefresher`
    /// reads THIS instead of constructing a throwaway `APIClient()`, which both
    /// (a) re-ran init's UserDefaults-mutating migration as a side effect, and
    /// (b) could resolve a DIFFERENT host than the instance that actually got the
    /// 401 — so a backend switch / saved-URL change refreshed to the wrong server.
    static var currentBaseURL = defaultURL

    /// Dev backend host — the Mac's LAN address (`ipconfig getifaddr en0`) so
    /// BOTH the simulator AND a real iPhone on the same WiFi can reach it. A
    /// loopback host (localhost/127.0.0.1) only works on the simulator; on a
    /// real device 127.0.0.1 is the phone itself. Run uvicorn with
    /// `--host 0.0.0.0` so the LAN IP is reachable. Update if the Mac IP changes.
    static let localDevHost = "192.168.1.175"

    /// Local dev preset — used by the DEBUG-only Local/Production picker in
    /// HomeSettingsSheet. Path keeps `/api/v1` so chat / queue / etc. route
    /// the same as on prod.
    static let localDevURL = "http://\(localDevHost):8000/api/v1"

    /// §14.4 — a stable per-install UUID minted once and persisted, so POST
    /// /family/create is idempotent across timeout-retries (the backend returns
    /// the SAME family/device/code for a repeated install id instead of creating
    /// a duplicate family).
    static let clientInstallIDKey = "evlin.clientInstallID"

    static var clientInstallID: String {
        if let existing = UserDefaults.standard.string(forKey: clientInstallIDKey) { return existing }
        let fresh = UUID().uuidString
        UserDefaults.standard.set(fresh, forKey: clientInstallIDKey)
        return fresh
    }

    static func resetClientInstallID() {
        UserDefaults.standard.removeObject(forKey: clientInstallIDKey)
    }

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
        // In DEBUG (simulator/local dev) default to the local backend so the
        // onboarding "Dev sign in" hits localhost:8000 instead of production.
        #if DEBUG
        let fallbackURL = Self.localDevURL
        // A stale saved PRODUCTION url — Render, or a railway url the migration
        // above just rewrote to Render — must NOT shadow the local backend in a
        // debug build: /auth/dev-signin is debug-gated server-side (localhost
        // only), and Render's free-tier cold-start would hang the request with
        // no timeout. A purposely-saved localhost/LAN dev url is not a prod
        // host, so it is preserved.
        if saved.contains("onrender.com") || saved.contains("railway.app") {
            saved = ""
            UserDefaults.standard.removeObject(forKey: "serverURL")
        }
        #else
        let fallbackURL = Self.defaultURL
        // A production (Release / TestFlight) build must NEVER talk to a
        // LAN/loopback dev backend. If a stale dev URL is persisted from a
        // former dev build on this same install, drop it so we fall back to
        // the Render default — otherwise the public build silently hits an
        // unreachable Mac (or shows that dev backend's data). Production is
        // always HTTPS to Render, so any http:// / localhost / private-IP /
        // .local host is, by definition, a dev backend.
        if !saved.isEmpty,
           saved.hasPrefix("http://")
            || saved.contains("localhost")
            || saved.contains("127.0.0.1")
            || saved.contains("192.168.")
            || saved.contains("10.0.")
            || saved.contains(".local") {
            saved = ""
            UserDefaults.standard.removeObject(forKey: "serverURL")
        }
        #endif
        let useSaved = !saved.isEmpty
        var raw = baseURL.isEmpty
            ? (useSaved ? saved : fallbackURL)
            : baseURL
        #if DEBUG
        // A loopback host only works on the simulator — on a real iPhone
        // localhost/127.0.0.1 is the phone itself, so the dev backend is
        // unreachable ("could not connect to the server"). Rewrite any stale
        // loopback dev url to the Mac's LAN IP, which both the simulator and a
        // real device on the same WiFi can reach.
        raw = raw.replacingOccurrences(of: "//localhost", with: "//\(Self.localDevHost)")
        raw = raw.replacingOccurrences(of: "//127.0.0.1", with: "//\(Self.localDevHost)")
        #endif
        // Guard against missing scheme (user typed raw host in Settings)
        if raw.hasPrefix("http://") || raw.hasPrefix("https://") {
            self.baseURL = raw
        } else {
            self.baseURL = "https://" + raw
        }
        // Mirror the resolved host process-wide so `sharedRefresher` refreshes
        // against the SAME backend this live instance uses (see currentBaseURL).
        Self.currentBaseURL = self.baseURL
    }

    nonisolated deinit {}

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
        // Chat-history (B3): client-generated UUID that identifies the current
        // conversation. Sent on every /parent/chat turn and feedback call.
        // NOT sent on /parent/chat/answer-question (server derives it from the
        // stored pending question). Rotated on Clear; set on open-history.
        let conversation_id: String?
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
        forceConfirmations: [String] = [],
        childDeviceID: String? = nil
    ) async throws -> ChatResponse {
        // Read paired family_id from UserDefaults so commands get queued to the child device.
        let familyID = UserDefaults.standard.string(forKey: "evlin.familyID")
        // child_device_id is passed in by the caller (resolved via
        // ChatViewModel.effectiveChildDeviceID so multi-child families send nil → backend gate).

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
                child_device_id: childDeviceID,
                client_alias_state: [
                    "known_apps": LocalAliasStore.shared.allApplicationKeys(),
                    "known_categories": LocalAliasStore.shared.allCategoryNames()
                ],
                // Legacy APIClient.chat() path always lets the backend fastpath
                // attempt to handle the message — the reinterpret flow goes
                // through ChatViewModel.sendChatMessageWithRawData(), which
                // sets skip_fastpath=true explicitly.
                skip_fastpath: false,
                conversation_id: nil
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
        Self.currentBaseURL = url
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
    let all_selected: Bool?              // Task 3: kid's saved-list selection was "all" at upload time
    let default_lock_group: Bool?        // command targets the default "Locked set"
    let original_request: String
    let target_display: String?
    let target_child_id: String?         // new: which child device (multi-child)
    let force_downgrade: Bool?           // new: parent-confirmed B1 downgrade
    let catalog_token_data_base64: String?
    let catalog_category_token_data_base64: String?
    let applications: [String]?
    let applicationCategories: [String]?
    // B2: per-target provenance. Backend emits "earned_time"|"manual".
    let lock_source: String?
    let unlock_sources: [String]?
    let earned_override_usage_date: String?

    private enum CodingKeys: String, CodingKey {
        case bundle_id
        case list_name
        case list_id
        case has_pending_blob
        case category_hint
        case categoryHint
        case target_all
        case all_selected
        case default_lock_group
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
        case lock_source
        case unlock_sources
        case earned_override_usage_date
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
        all_selected = try c.decodeIfPresent(Bool.self, forKey: .all_selected)
        default_lock_group = try c.decodeIfPresent(Bool.self, forKey: .default_lock_group)
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
        lock_source = try c.decodeIfPresent(String.self, forKey: .lock_source)
        unlock_sources = try c.decodeIfPresent([String].self, forKey: .unlock_sources)
        earned_override_usage_date =
            try c.decodeIfPresent(String.self, forKey: .earned_override_usage_date)
    }
}

/// GET /child/app-limits/snapshot wire shapes. `payload` deliberately mirrors
/// PollCommandDTO minus `command_id` — the snapshot describes a command at
/// rest, and the backend builds both from one canonical builder.
struct AppLimitSnapshotDTO: Decodable {
    let child_device_id: UUID
    let child_profile_id: UUID?
    let server_revision: String?
    let rules_digest: String
    let items: [AppLimitSnapshotItemDTO]
}

struct AppLimitSnapshotItemDTO: Decodable {
    let kind: String              // "set" | "clear" | "unknown"
    let rule_id: UUID
    let ordering_token: Int64
    let status: String
    let payload: AppLimitSnapshotSetPayloadDTO?
    let clear: PollClearDTO?
    let unavailable_reason: String?
    let updated_at: String?
}

struct AppLimitSnapshotSetPayloadDTO: Decodable {
    let action: String
    let tier: String?
    let target: PollTargetDTO
    let duration_minutes: Int?
    let issued_at: String
    let limit: PollLimitDTO?
}

struct PollCommandDTO: Decodable {
    let command_id: UUID
    let action: String
    let tier: String?
    let target: PollTargetDTO
    let duration_minutes: Int?
    let issued_at: String
    // Per-app time-limit payloads (P3). Synthesized Decodable performs
    // decodeIfPresent for these optionals, so commands without the keys still
    // decode unchanged.
    let limit: PollLimitDTO?
    let clear: PollClearDTO?
    // B2: top-level provenance (takes precedence over target.lock_source).
    let lock_source: String?
    let unlock_sources: [String]?
    /// A4: present when action == "earned_time_config". Nil for all other actions.
    let earned_time_config: PollEarnedTimeConfigDTO?
}

/// `set_limit.limit` wire payload (P3 decode only). Literal snake_case stored
/// property names — this codebase does NOT use `convertFromSnakeCase`. ISO8601
/// timestamps are carried as `String` (matching `PollCommandDTO.issued_at`) and
/// parsed to `Date` at the LockCommand mapping layer.
struct PollLimitDTO: Decodable {
    let rule_id: UUID
    let orderingToken: Int64
    let daily_budget_minutes: Int
    let reset_policy: String
    let schedule: PollLimitScheduleDTO
    let effective_from: String
    let expires_at: String?
    let updated_at: String
    /// Minutes already used today (backend-authoritative). Optional for forward/
    /// backward wire-skew safety — absent on older backends → nil.
    let used_today_minutes: Int?

    private enum CodingKeys: String, CodingKey {
        case rule_id
        case orderingToken = "ordering_token"
        case daily_budget_minutes
        case reset_policy
        case schedule
        case effective_from
        case expires_at
        case updated_at
        case used_today_minutes
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        rule_id = try container.decode(UUID.self, forKey: .rule_id)
        orderingToken = try OrderingTokenDecoding.decode(from: container, forKey: .orderingToken)
        daily_budget_minutes = try container.decode(Int.self, forKey: .daily_budget_minutes)
        reset_policy = try container.decode(String.self, forKey: .reset_policy)
        schedule = try container.decode(PollLimitScheduleDTO.self, forKey: .schedule)
        effective_from = try container.decode(String.self, forKey: .effective_from)
        expires_at = try container.decodeIfPresent(String.self, forKey: .expires_at)
        updated_at = try container.decode(String.self, forKey: .updated_at)
        used_today_minutes = try container.decodeIfPresent(Int.self, forKey: .used_today_minutes)
    }
}

/// `set_limit.limit.schedule` wire payload. `starts_at`/`ends_at` stay as
/// "HH:mm" STRINGS here; parsing to minutes happens at the mapping layer.
struct PollLimitScheduleDTO: Decodable {
    let starts_at: String
    let ends_at: String
    let timezone: String?
}

/// `clear_limit.clear` wire payload (P3 decode only).
struct PollClearDTO: Decodable {
    let rule_id: UUID
    let orderingToken: Int64
    let reason: String?
    let updated_at: String

    private enum CodingKeys: String, CodingKey {
        case rule_id
        case orderingToken = "ordering_token"
        case reason
        case updated_at
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        rule_id = try container.decode(UUID.self, forKey: .rule_id)
        orderingToken = try OrderingTokenDecoding.decode(from: container, forKey: .orderingToken)
        reason = try container.decodeIfPresent(String.self, forKey: .reason)
        updated_at = try container.decode(String.self, forKey: .updated_at)
    }
}

/// A4: `earned_time_config` top-level payload (same-day pool/cap sync from
/// backend). Literal snake_case stored property names — this codebase does NOT
/// use `convertFromSnakeCase`. Synthesized `Decodable` handles all optionals.
typealias PollEarnedTimeConfigDTO = EarnedTimeConfigCommand

/// A4: `earned_time_config.selected_set` nested payload.
typealias PollEarnedConfigSelectedSetDTO = EarnedTimeConfigSelectedSet

// MARK: - v2 ack-status decode

struct AckPendingConfirmation: Decodable, Sendable {
    let card_id: String
    let context: [String: String]
}

struct AckStatusResponse: Decodable, Sendable {
    let status: String  // "pending" | "confirmed" | "failed" | "timeout" | "pending_confirmation"
    let deliveryState: String?
    let createdAt: String?
    let pickedUpAt: String?
    let ackedAt: String?
    let verb: String?
    let detail: [String: AnyCodable]?
    let displayName: String?
    let bundleID: String?
    let artworkURL: URL?
    /// "app" | "category" | "list" | "all" — drives the receipt's icon so a
    /// category lock shows a category glyph, not an app artwork resolved by name.
    let targetType: String?
    let category: String?
    let origRequest: String?
    let effectiveState: AckEffectiveState?
    let pendingConfirmation: AckPendingConfirmation?

    enum CodingKeys: String, CodingKey {
        case status
        case deliveryState = "delivery_state"
        case createdAt = "created_at"
        case pickedUpAt = "picked_up_at"
        case ackedAt = "acked_at"
        case verb
        case detail
        case displayName
        case bundleID = "bundle_id"
        case artworkURL = "artwork_url"
        case targetType = "target_type"
        case category
        case origRequest
        case effectiveState
        case pendingConfirmation
    }
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

enum CatalogListMemberTargetType: String, Codable, Sendable, Equatable, Hashable {
    case app
    case category
}

struct CatalogListMemberDTO: Codable, Sendable, Equatable, Hashable {
    let targetType: CatalogListMemberTargetType
    let aliasKey: UUID

    enum CodingKeys: String, CodingKey {
        case targetType = "target_type"
        case aliasKey = "alias_key"
    }
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
    let allSelected: Bool

    init(
        deviceID: UUID,
        aliasKey: UUID?,
        sourceDeviceID: UUID?,
        listName: String,
        aliases: [String],
        selectionBlobBase64: String?,
        appCount: Int,
        members: [CatalogListMemberUpload]?,
        allSelected: Bool = false
    ) {
        self.deviceID = deviceID
        self.aliasKey = aliasKey
        self.sourceDeviceID = sourceDeviceID
        self.listName = listName
        self.aliases = aliases
        self.selectionBlobBase64 = selectionBlobBase64
        self.appCount = appCount
        self.members = members
        self.allSelected = allSelected
    }

    enum CodingKeys: String, CodingKey {
        case deviceID = "device_id"
        case aliasKey = "alias_key"
        case sourceDeviceID = "source_device_id"
        case listName = "list_name"
        case aliases
        case selectionBlobBase64 = "selection_blob_base64"
        case appCount = "app_count"
        case members
        case allSelected = "all_selected"
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
    let members: [CatalogListMemberDTO]

    enum CodingKeys: String, CodingKey {
        case aliasKey = "alias_key"
        case targetType = "target_type"
        case listName = "list_name"
        case aliases
        case appCount = "app_count"
        case status
        case members
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        aliasKey = try container.decode(UUID.self, forKey: .aliasKey)
        targetType = try container.decode(LazyTagCatalogTargetType.self, forKey: .targetType)
        listName = try container.decode(String.self, forKey: .listName)
        aliases = try container.decodeIfPresent([String].self, forKey: .aliases) ?? []
        appCount = try container.decodeIfPresent(Int.self, forKey: .appCount) ?? 0
        status = try container.decodeIfPresent(String.self, forKey: .status) ?? "active"
        members = try container.decodeIfPresent([CatalogListMemberDTO].self, forKey: .members) ?? []
    }

    var lazyTagTarget: LazyTagCatalogTarget {
        LazyTagCatalogTarget(
            aliasKey: aliasKey,
            type: .list,
            displayName: listName,
            aliases: aliases,
            memberCount: appCount,
            members: members
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
        let members: [CatalogListMemberDTO]

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
            case members
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
            members = try c.decodeIfPresent([CatalogListMemberDTO].self, forKey: .members) ?? []
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
                memberCount: targetType == .list ? appCount : nil,
                members: targetType == .list ? members : []
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
    /// True when the kid's raw `FamilyActivitySelection` represents "all apps
    /// and categories" rather than a specific subset. Computed on-device (the
    /// backend cannot see Apple's picker semantics) via
    /// `LockedSetSelectionSemantics.isAllSelected(_:)`. Defaults to `false` —
    /// safe default until a reliable device-local signal is wired in. See
    /// `LockedSetSelectionSemantics.swift` for what to verify before flipping
    /// this on for real.
    let allSelected: Bool

    init(
        aliasKey: UUID? = nil,
        listName: String,
        aliases: [String] = [],
        members: [CatalogListMemberUpload],
        selectionBlobBase64: String? = nil,
        allSelected: Bool = false
    ) {
        self.aliasKey = aliasKey
        self.listName = listName
        self.aliases = aliases
        self.members = members
        self.selectionBlobBase64 = selectionBlobBase64
        self.allSelected = allSelected
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
    let parent_pin_status: String?
    let parent_pin: String?
    let metering_ready: Bool?
    var id: String { device_id }

    init(
        device_id: String,
        mode: String,
        label: String?,
        device_model: String?,
        platform: String?,
        os_version: String?,
        display: String?,
        last_seen_at: String?,
        online: Bool,
        is_self: Bool,
        parent_pin_status: String? = nil,
        parent_pin: String? = nil,
        metering_ready: Bool? = nil
    ) {
        self.device_id = device_id
        self.mode = mode
        self.label = label
        self.device_model = device_model
        self.platform = platform
        self.os_version = os_version
        self.display = display
        self.last_seen_at = last_seen_at
        self.online = online
        self.is_self = is_self
        self.parent_pin_status = parent_pin_status
        self.parent_pin = parent_pin
        self.metering_ready = metering_ready
    }
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

/// GET /family/onboarding/child-readiness — kid onboarding readiness for the
/// parent's wait gate + first-block target (P3).
struct ChildReadinessDTO: Codable, Sendable, Equatable {
    struct App: Codable, Sendable, Equatable {
        let alias_key: UUID
        let display_name: String
        let bundle_id: String?
        let token_available: Bool
        let status: String
    }
    let child_device_id: UUID
    let child_profile_id: UUID?
    let display_name: String?
    let screen_time_granted: Bool
    let lockable_app_count: Int
    let first_block_app: App?
    let ready_for_first_block: Bool
    /// True once the kid reached the "All set!" screen (POST /child-all-set).
    /// Optional so older responses without the field still decode.
    let all_set: Bool?
}

struct AvatarUploadResponseDTO: Codable, Sendable, Equatable {
    let signed_url: String?
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

    /// Parent uploads its APNs token to its own account-scoped Device row.
    /// Do not use `/child/register-apns` for parent devices: that endpoint has no
    /// auth context and leaves the parent row account-less, which makes parent
    /// reflection/nudge pushes attach to the wrong recipient.
    func registerParentAPNsToken(deviceID: UUID, token: String) async throws {
        var req = authedRequest(path: "/family/device/register", method: "POST")
        req.setValue(deviceID.uuidString, forHTTPHeaderField: "X-Device-Id")
        let info = DeviceInfoProvider.current()
        let body: [String: Any] = [
            "label": "iPhone",
            "device_model": info.device_model,
            "device_model_id": info.device_model_id,
            "platform": info.platform,
            "os_version": info.os_version,
            "apns_token": token
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, http) = try await authedData(for: req)
        guard (200..<300).contains(http.statusCode) else {
            throw APIError.serverError(http.statusCode)
        }
        _ = data
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
        let (_, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else {
            throw APIError.serverError((response as? HTTPURLResponse)?.statusCode ?? -1)
        }
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
        members: [CatalogListMemberUpload]? = nil,
        allSelected: Bool = false
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
                members: members,
                allSelected: allSelected
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

    func childLockSetupCatalogURL(deviceID: UUID) -> URL {
        var comps = URLComponents(string: "\(baseURL)/child/lock-setup-catalog")!
        comps.queryItems = [URLQueryItem(name: "device_id", value: deviceID.uuidString)]
        return comps.url!
    }

    /// Fetch the kid-scoped Lock-setup catalog for the current child device.
    /// The backend requires the header to match `device_id` as a scoping guard.
    func fetchChildLockSetupCatalog(deviceID: UUID) async throws -> LockSetupCatalog {
        var req = URLRequest(url: childLockSetupCatalogURL(deviceID: deviceID))
        req.timeoutInterval = 22
        req.setValue(deviceID.uuidString, forHTTPHeaderField: "X-Evlin-Child-Device-ID")
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
            throw APIError.serverError((resp as? HTTPURLResponse)?.statusCode ?? 0)
        }
        return try JSONDecoder().decode(LockSetupCatalog.self, from: data)
    }

    /// GET /child/app-limits/snapshot — the per-app recovery leg.
    ///
    /// An authoritative, side-effect-free description of every rule this
    /// device should hold. Each `set` item's `payload` is byte-identical to a
    /// wire `set_limit` command (single builder on the backend), so the client
    /// re-uses the whole command pipeline to apply it.
    func fetchAppLimitSnapshot(deviceID: UUID) async throws -> (AppLimitSnapshotDTO, Data) {
        var comps = URLComponents(string: "\(baseURL)/child/app-limits/snapshot")!
        comps.queryItems = [URLQueryItem(name: "device_id", value: deviceID.uuidString)]
        var req = URLRequest(url: comps.url!)
        req.timeoutInterval = 22
        req.setValue(deviceID.uuidString, forHTTPHeaderField: "X-Evlin-Child-Device-ID")
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
            throw APIError.serverError((resp as? HTTPURLResponse)?.statusCode ?? 0)
        }
        return (try JSONDecoder().decode(AppLimitSnapshotDTO.self, from: data), data)
    }

    func deleteChildAppControlTarget(deviceID: UUID, aliasKey: UUID) async throws {
        var comps = URLComponents(string: "\(baseURL)/child/app-controls-targets/\(aliasKey.uuidString)")!
        comps.queryItems = [URLQueryItem(name: "device_id", value: deviceID.uuidString)]
        var req = URLRequest(url: comps.url!)
        req.httpMethod = "DELETE"
        req.timeoutInterval = 22
        req.setValue(deviceID.uuidString, forHTTPHeaderField: "X-Evlin-Child-Device-ID")
        let (_, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
            throw APIError.serverError((resp as? HTTPURLResponse)?.statusCode ?? 0)
        }
    }

    @discardableResult
    func mergeChildAppCatalog(
        deviceID: UUID,
        apps: [ChildAppCatalogUploadApp]
    ) async throws -> ChildAppCatalogUploadResponse {
        let url = URL(string: "\(baseURL)/child/app-catalog/merge")!
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
            members: list.members,
            allSelected: list.allSelected
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
            members: list.members,
            allSelected: list.allSelected
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

struct NotificationPreferencesDTO: Codable, Sendable, Equatable {
    var quiet_hours_start: Int?
    var quiet_hours_end: Int?
    var digest_enabled: Bool
    var muted_types: [String]
}

struct UpdateNotificationPreferencesBody: Codable {
    var quiet_hours_start: Int?
    var quiet_hours_end: Int?
    var digest_enabled: Bool?
    var muted_types: [String]?
}

/// Wire DTO for GET /me/agreement and POST /me/agreement/ack.
struct AgreementAckStatusDTO: Decodable {
    let acked_version: String?
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

    /// GET /me/export — everything Evlin stores for this account and family,
    /// as JSON (Beta Participation Agreement §5.4(a) review right). Returns the
    /// raw bytes so the caller can hand them straight to a share sheet.
    /// 🔑 get_current_account.
    func fetchDataExport() async throws -> Data {
        let req = authedRequest(path: "/me/export", method: "GET")
        let (data, http) = try await authedData(for: req)
        guard (200..<300).contains(http.statusCode) else {
            throw APIError.serverError(http.statusCode)
        }
        return data
    }

    /// DELETE /auth/account — permanently delete the signed-in parent account.
    /// The backend transfers family ownership when other parents remain, and
    /// cascades the whole family when this is the last one. Throws on any
    /// non-2xx so the caller can keep the local data until the server confirms.
    /// 🔑 get_current_account.
    func deleteAccount() async throws {
        var req = authedRequest(path: "/auth/account", method: "DELETE")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["confirm": true])
        let (_, http) = try await authedData(for: req)
        guard (200..<300).contains(http.statusCode) else {
            throw APIError.serverError(http.statusCode)
        }
    }

    /// GET /me/agreement — which Beta Participation Agreement version this
    /// account has acknowledged (nil = never). Drives the parent-root launch
    /// gate. 🔑 get_current_account.
    func fetchAgreementAck() async throws -> AgreementAckStatusDTO {
        try await authedJSON(path: "/me/agreement", method: "GET")
    }

    /// POST /me/agreement/ack — record that the signed-in parent read the
    /// given agreement version to the end. Idempotent. 🔑 get_current_account.
    @discardableResult
    func postAgreementAck(version: String) async throws -> AgreementAckStatusDTO {
        let body = try JSONSerialization.data(withJSONObject: ["version": version])
        return try await authedJSON(path: "/me/agreement/ack", method: "POST", jsonBody: body)
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

    /// GET /family/onboarding/child-readiness — parent polls the kid's onboarding
    /// progress (Screen Time granted + a lockable app) to know when the first
    /// real block can be sent. Replaces the fake "Simulate kid ready" gate.
    func fetchChildReadiness(childDeviceID: UUID) async throws -> ChildReadinessDTO {
        try await authedJSON(
            path: "/family/onboarding/child-readiness?child_device_id=\(childDeviceID.uuidString)",
            method: "GET")
    }

    func fetchNotificationPreferences() async throws -> NotificationPreferencesDTO {
        try await authedJSON(path: "/me/notification-preferences", method: "GET")
    }

    @discardableResult
    func updateNotificationPreferences(_ body: UpdateNotificationPreferencesBody) async throws -> NotificationPreferencesDTO {
        let payload = try JSONEncoder().encode(body)
        return try await authedJSON(path: "/me/notification-preferences", method: "PUT", jsonBody: payload)
    }

    /// POST /family/onboarding/child-all-set — the kid reports it reached the
    /// "All set!" screen so the parent's waiting-for-kid screen advances.
    ///
    /// This is the SINGLE signal that flips the backend `child_onboarding_complete`
    /// flag the parent's poll gates on. It used to be a one-shot fire-and-forget
    /// POST: a single dropped/cancelled request stranded the parent on the waiting
    /// screen forever. It now RETRIES with backoff until the (idempotent) write
    /// lands. Unauthed — the kid device has no session.
    @discardableResult
    func markChildAllSet(childDeviceID: UUID) async -> Bool {
        let base = baseURL
        return await Self.deliverAllSet(childDeviceID: childDeviceID) { id in
            await Self.postChildAllSetOnce(baseURL: base, childDeviceID: id)
        }
    }

    /// Retry an idempotent all-set delivery until `perform` reports success or
    /// `maxAttempts` is exhausted. Backoff doubles 0.5s → 8s (capped). `sleep`
    /// and `perform` are injected so the policy is unit-tested without the network.
    static func deliverAllSet(
        childDeviceID: UUID,
        maxAttempts: Int = 8,
        sleep: (UInt64) async -> Void = { try? await Task.sleep(nanoseconds: $0) },
        perform: (UUID) async -> Bool
    ) async -> Bool {
        let attempts = max(1, maxAttempts)
        for attempt in 0..<attempts {
            if await perform(childDeviceID) { return true }
            if attempt < attempts - 1 {
                let backoffMs = min(8_000, 500 << min(attempt, 4))
                await sleep(UInt64(backoffMs) * 1_000_000)
            }
        }
        return false
    }

    /// One unauthed POST to /family/onboarding/child-all-set. Returns true on 2xx.
    private static func postChildAllSetOnce(baseURL: String, childDeviceID: UUID) async -> Bool {
        guard let url = URL(string: "\(baseURL)/family/onboarding/child-all-set") else { return false }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 12
        req.httpBody = try? JSONSerialization.data(
            withJSONObject: ["child_device_id": childDeviceID.uuidString])
        guard let (_, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse else { return false }
        return (200...299).contains(http.statusCode)
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

    struct AvatarUploadResponse: Decodable, Sendable {
        let ok: Bool
        let object_key: String
        let signed_url: String?
    }

    /// POST /me/avatar — upload the parent's avatar photo (authed). The backend
    /// stores it (local DB now, Supabase in prod) + sets avatar_kind=photo, so
    /// the photo shows on Home.
    @discardableResult
    func uploadParentAvatar(jpegData: Data) async throws -> AvatarUploadResponse {
        let body: [String: Any] = ["image_base64": jpegData.base64EncodedString(),
                                    "content_type": "image/jpeg"]
        let payload = try JSONSerialization.data(withJSONObject: body)
        return try await authedJSON(path: "/me/avatar", method: "POST", jsonBody: payload)
    }

    /// POST /child/avatar?child_device_id= — upload the kid's avatar photo
    /// (UNauthed, keyed by the child device, like /family/create).
    func uploadChildAvatar(childDeviceID: UUID, jpegData: Data) async throws {
        let url = URL(string: "\(baseURL)/child/avatar?child_device_id=\(childDeviceID.uuidString)")!
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 20
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = ["image_base64": jpegData.base64EncodedString(),
                                    "content_type": "image/jpeg"]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (_, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
            throw APIError.serverError((resp as? HTTPURLResponse)?.statusCode ?? 0)
        }
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

    /// End one child device's enrollment while preserving its server history.
    /// The removed K device receives the existing terminal 410 cleanup path the
    /// next time it connects; this request itself is parent-authenticated.
    func removeChildDevice(childID: String, deviceID: String) async throws {
        let req = authedRequest(
            path: "/family/children/\(childID)/devices/\(deviceID)",
            method: "DELETE",
            timeoutInterval: 15
        )
        let (_, http) = try await authedData(for: req)
        guard (200..<300).contains(http.statusCode) else {
            throw APIError.serverError(http.statusCode)
        }
    }

    /// Parent-authenticated recovery exit for a stale or unrecoverable PIN.
    func clearChildDeviceParentPIN(childID: String, deviceID: String) async throws {
        let req = authedRequest(
            path: "/family/children/\(childID)/devices/\(deviceID)/parent-pin",
            method: "DELETE",
            timeoutInterval: 15
        )
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
        protectionMode: String? = nil,
        targetChildProfileID: String? = nil
    ) async throws -> PairResponseDTO {
        var body: [String: Any] = [
            "code": code,
            "parent_device_label": deviceLabel,
        ]
        if let protectionMode { body["protection_mode"] = protectionMode }
        if let targetChildProfileID { body["target_child_profile_id"] = targetChildProfileID }
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
    /// Resolve the install-id sent to /family/create. Single Device Mode passes a per-run
    /// override (a fresh UUID) so a reset+rerun creates a brand-new child row instead of the
    /// idempotent one; everyone else uses the stable per-install id.
    static func resolveInstallID(_ override: String?) -> String {
        let o = (override ?? "").trimmingCharacters(in: .whitespaces)
        return o.isEmpty ? clientInstallID : o
    }

    func createFamily(
        childDeviceLabel: String,
        protectionMode: String = "std",
        childDisplayName: String? = nil,
        childBirthYear: Int? = nil,
        childGender: String? = nil,
        resetChildAvatar: Bool = false,
        clientInstallIDOverride: String? = nil
    ) async throws -> CreateFamilyResponseDTO {
        let url = URL(string: "\(baseURL)/family/create")!
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 15
        let info = DeviceInfoProvider.current()
        var body: [String: Any] = [
            "child_device_label": childDeviceLabel,
            "protection_mode": protectionMode,
            "device_model": info.device_model,
            "device_model_id": info.device_model_id,
            "platform": info.platform,
            "os_version": info.os_version,
            // F7: stable idempotency key so a timed-out retry reuses the same family.
            // Single Device Mode overrides it per-run (fresh family each demo).
            "client_install_id": Self.resolveInstallID(clientInstallIDOverride),
        ]
        // F6: persist the kid-entered profile as a ChildProfile server-side so the
        // parent's Home shows the real child after pairing.
        if let n = childDisplayName, !n.isEmpty { body["child_display_name"] = n }
        if let by = childBirthYear { body["child_birth_year"] = by }
        if let g = childGender { body["child_gender"] = g }
        if resetChildAvatar { body["child_avatar_reset"] = true }
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

    /// POST /family/children/{id}/avatar — parent-side upload of a child avatar
    /// photo. Returns the fresh signed URL so Settings can update immediately.
    func uploadChildAvatar(childId: String, jpegData: Data) async throws -> String? {
        let body: [String: Any] = [
            "image_base64": jpegData.base64EncodedString(),
            "content_type": "image/jpeg",
        ]
        let payload = try JSONSerialization.data(withJSONObject: body)
        let decoded: AvatarUploadResponseDTO = try await authedJSON(
            path: "/family/children/\(childId)/avatar",
            method: "POST",
            jsonBody: payload
        )
        return decoded.signed_url ?? decoded.avatar_url
    }
}

// MARK: - Calendar events (spec §"Surface 3 — Calendar")
//
// Authed family-scoped CRUD over /calendar/events. Goes through the same
// single-flight-refresh authed layer as /me/profile + /family/children (no new
// interceptor). This extension MUST live in APIClient.swift so it can call the
// file-private `authedJSON` helper. The window URL builder is factored out so it
// is unit-testable.
//
// Two response shapes (match the backend exactly):
//   • GET  → envelope `{ "occurrences": [CalendarOccurrenceDTO] }` (event_id).
//   • POST/PUT → `CalendarEventDTO` (id). DELETE → `{ ok, deleted }`.

extension APIClient {
    /// Builds `GET /calendar/events?start=<iso>&end=<iso>` as a FULL url (used by
    /// a unit test to assert the path/query). The runtime fetch passes only the
    /// RELATIVE path+query to `authedRequest` so `baseURL`'s `/api/v1` prefix is
    /// not duplicated.
    func calendarEventsWindowURL(startISO: String, endISO: String) -> URL {
        var comps = URLComponents(string: "\(baseURL)/calendar/events")!
        comps.queryItems = [
            URLQueryItem(name: "start", value: startISO),
            URLQueryItem(name: "end", value: endISO),
        ]
        return comps.url!
    }

    /// Relative `/calendar/events?start=&end=` path (no baseURL, no double
    /// `/api/v1`). Encodes the ISO instants as query items so `+`/`:` are escaped.
    func calendarEventsWindowPath(startISO: String, endISO: String) -> String {
        var comps = URLComponents()
        comps.path = "/calendar/events"
        comps.queryItems = [
            URLQueryItem(name: "start", value: startISO),
            URLQueryItem(name: "end", value: endISO),
        ]
        // comps.string is "/calendar/events?start=...&end=..." — exactly the
        // relative path `authedRequest` expects appended to baseURL.
        return comps.string ?? "/calendar/events"
    }

    /// GET /calendar/events — occurrences overlapping [start,end], recurrence
    /// already expanded server-side. Decodes the `{ "occurrences": [...] }`
    /// envelope and returns the occurrence array. Family-scoped.
    func fetchCalendarEvents(startISO: String, endISO: String) async throws -> [CalendarOccurrenceDTO] {
        let path = calendarEventsWindowPath(startISO: startISO, endISO: endISO)
        let envelope: CalendarEventsListResponse = try await authedJSON(path: path, method: "GET")
        return envelope.occurrences
    }

    /// POST /calendar/events — create. Returns the persisted base event.
    @discardableResult
    func createCalendarEvent(_ body: CalendarEventCreateBody) async throws -> CalendarEventDTO {
        let payload = try JSONEncoder().encode(body)
        return try await authedJSON(path: "/calendar/events", method: "POST", jsonBody: payload)
    }

    /// PUT /calendar/events/{id} — update (whole series in P0). Returns the event.
    @discardableResult
    func updateCalendarEvent(id: UUID, _ body: CalendarEventUpdateBody) async throws -> CalendarEventDTO {
        let payload = try JSONEncoder().encode(body)
        return try await authedJSON(path: "/calendar/events/\(id.uuidString)", method: "PUT", jsonBody: payload)
    }

    /// DELETE /calendar/events/{id} — soft delete server-side.
    func deleteCalendarEvent(id: UUID) async throws {
        let req = authedRequest(path: "/calendar/events/\(id.uuidString)", method: "DELETE")
        let (_, http) = try await authedData(for: req)
        guard (200..<300).contains(http.statusCode) else {
            throw APIError.serverError(http.statusCode)
        }
    }

    // MARK: Device lock-all (Profile "Lock devices" CTA)

    struct DeviceLockAllResponse: Decodable {
        let command_id: UUID
        let action: String
    }

    private struct DeviceLockAllBody: Encodable {
        let family_id: UUID
        let child_device_id: UUID
    }

    /// POST /parent/device/lock-all — queues the all-apps shield on the kid
    /// device (same mechanism the reflection lockdown applies), permanent
    /// until `unlockAllApps`. The kid's CommandPoller applies it on its next
    /// poll.
    @discardableResult
    func lockAllApps(familyID: UUID, childDeviceID: UUID) async throws -> DeviceLockAllResponse {
        let payload = try JSONEncoder().encode(
            DeviceLockAllBody(family_id: familyID, child_device_id: childDeviceID))
        return try await authedJSON(path: "/parent/device/lock-all", method: "POST", jsonBody: payload)
    }

    /// POST /parent/device/unlock-all — reverses `lockAllApps` (unshield_all).
    @discardableResult
    func unlockAllApps(familyID: UUID, childDeviceID: UUID) async throws -> DeviceLockAllResponse {
        let payload = try JSONEncoder().encode(
            DeviceLockAllBody(family_id: familyID, child_device_id: childDeviceID))
        return try await authedJSON(path: "/parent/device/unlock-all", method: "POST", jsonBody: payload)
    }

    /// B8 §5.4 — full lock-state shape returned by GET /parent/device/lock-state
    /// (and equivalently by lock-selected / unlock-selected). Back-compat: all
    /// fields except `locked` are optional so old backends ({locked:bool} only)
    /// still decode cleanly.
    ///
    /// Mixed-casing rule (NO convertFromSnakeCase):
    ///   • `recordKey` / `targetKey` → camelCase (explicit CodingKeys below)
    ///   • everything else             → snake_case
    struct DeviceLockStateResponse: Decodable, Sendable {
        // Always present
        let locked: Bool

        // Optional — new fields added in B8; absent on old backends.
        let child_profile_id: UUID?
        let child_device_id: UUID?
        /// The backend ChildCatalogList.id for the Locked Set (B6 carry).
        let list_id: String?
        /// camelCase: CodingKey = "recordKey"
        let recordKey: String?
        /// camelCase: CodingKey = "targetKey"
        let targetKey: String?
        let tier: String?
        /// Which shield sources currently cover the selected set.
        /// Values: "manual" | "limit" | "earnedTime"
        let covering_sources: [String]?
        /// True when the kid's earned-time budget is exhausted for today.
        let exhausted: Bool?
        let override_active: Bool?
        let updated_at: String?
        let warning: String?

        // Explicit CodingKeys: recordKey/targetKey are camelCase; all others
        // use their natural snake_case names (no conversion).
        enum CodingKeys: String, CodingKey {
            case locked
            case child_profile_id
            case child_device_id
            case list_id
            case recordKey        // camelCase on the wire
            case targetKey        // camelCase on the wire
            case tier
            case covering_sources
            case exhausted
            case override_active
            case updated_at
            case warning
        }
    }

    /// GET /parent/device/lock-state — the kid device's real lock truth, so the
    /// Profile button + Home card can show the actual state instead of an
    /// ephemeral optimistic flip.
    func fetchDeviceLockState(familyID: UUID, childDeviceID: UUID) async throws -> DeviceLockStateResponse {
        try await authedJSON(
            path: "/parent/device/lock-state?family_id=\(familyID.uuidString)&child_device_id=\(childDeviceID.uuidString)",
            method: "GET")
    }

    // MARK: B8 — Selected-set lock/unlock

    private struct LockSelectedBody: Encodable {
        let family_id: UUID
        let child_profile_id: UUID
        let child_device_id: UUID
    }

    /// Decoded shape of POST /parent/device/{lock,unlock}-selected — the backend
    /// `ParentLockSelectedResponse`. This is the *queue-accepted* receipt, NOT a
    /// lock-state: it has NO `locked` field. The real locked truth is learned via
    /// the follow-up ack poll (`waitForLockStateAcked` / `fetchDeviceLockState`).
    /// Decoding this into `DeviceLockStateResponse` was the `keyNotFound("locked")`
    /// red-text bug — the lock had actually succeeded.
    struct LockSelectedResponse: Decodable {
        let command_id: UUID
        let action: String
        let list_id: UUID
        let warning: String?
    }

    /// POST /parent/device/lock-selected — queues a selected-set shield on the
    /// kid device (locks only the apps in the configured Locked Set list, not
    /// every app). The kid's CommandPoller applies it on its next poll.
    @discardableResult
    func lockSelected(familyID: UUID, childProfileID: UUID, childDeviceID: UUID) async throws -> LockSelectedResponse {
        let payload = try JSONEncoder().encode(
            LockSelectedBody(family_id: familyID, child_profile_id: childProfileID, child_device_id: childDeviceID))
        return try await authedJSON(path: "/parent/device/lock-selected", method: "POST", jsonBody: payload)
    }

    /// POST /parent/device/unlock-selected — reverses `lockSelected`.
    @discardableResult
    func unlockSelected(familyID: UUID, childProfileID: UUID, childDeviceID: UUID) async throws -> LockSelectedResponse {
        let payload = try JSONEncoder().encode(
            LockSelectedBody(family_id: familyID, child_profile_id: childProfileID, child_device_id: childDeviceID))
        return try await authedJSON(path: "/parent/device/unlock-selected", method: "POST", jsonBody: payload)
    }

    struct ChildSelectedSetBody: Encodable {
        let family_id: UUID
        let child_profile_id: UUID
        let operation_id: UUID
    }

    struct ChildSelectedSetDeviceReceipt: Decodable, Sendable {
        let child_device_id: UUID
        let command_id: UUID
        let list_id: UUID
        let warning: String?
    }

    struct ChildSelectedSetResponse: Decodable, Sendable {
        let action: String
        let devices: [ChildSelectedSetDeviceReceipt]
    }

    /// Adds the manual selected-set shield source to every device linked to the child.
    @discardableResult
    func lockSelectedForChild(
        familyID: UUID,
        childProfileID: UUID,
        operationID: UUID
    ) async throws -> ChildSelectedSetResponse {
        let payload = try JSONEncoder().encode(
            ChildSelectedSetBody(
                family_id: familyID,
                child_profile_id: childProfileID,
                operation_id: operationID
            ))
        return try await authedJSON(path: "/parent/child/lock-selected", method: "POST", jsonBody: payload)
    }

    /// Removes only the manual selected-set shield source from every linked device.
    @discardableResult
    func unlockSelectedForChild(
        familyID: UUID,
        childProfileID: UUID,
        operationID: UUID
    ) async throws -> ChildSelectedSetResponse {
        let payload = try JSONEncoder().encode(
            ChildSelectedSetBody(
                family_id: familyID,
                child_profile_id: childProfileID,
                operation_id: operationID
            ))
        return try await authedJSON(path: "/parent/child/unlock-selected", method: "POST", jsonBody: payload)
    }

    // MARK: B8 — Earned-time summary + policy + config

    /// Earned-time summary for one child device. State values: "ok" | "exhausted".
    struct EarnedSummaryDTO: Decodable {
        let child_profile_id: UUID?
        var usage_date: String? = nil
        let state: String?          // "ok" | "exhausted"
        let earned_minutes: Int?
        let used_minutes: Int?
        let remaining_minutes: Int?
        let override_active: Bool?
        let updated_at: String?
        // B11: coarse display fields from A3 backend summary.
        /// Pre-formatted countdown label from the server ("1h 5m left" / "30m left").
        /// When nil, the client computes from remaining_minutes via EarnedDisplayFormatters.
        let countdown_label: String?
        /// The child's daily earned-time pool in minutes (denominator for progress bar).
        let daily_pool_minutes: Int?
        /// Per-device estimated minutes left on each enrolled device.
        /// NOTE: A3 summary response returns this array under the JSON key "devices"
        /// (spec §5.2). CodingKeys below maps the Swift property to that key.
        let device_estimates: [EarnedDeviceEstimateDTO]?

        enum CodingKeys: String, CodingKey {
            case child_profile_id
            case usage_date
            case state
            case earned_minutes
            case used_minutes
            case remaining_minutes
            case override_active
            case updated_at
            case countdown_label
            case daily_pool_minutes
            case device_estimates = "devices"
        }
    }

    /// Per-device estimated remaining minutes. Part of EarnedSummaryDTO (B11).
    struct EarnedDeviceEstimateDTO: Decodable {
        let child_device_id: UUID?
        let estimated_minutes: Int?          // minutes USED on this device
        let remaining_to_cap_minutes: Int?   // minutes LEFT (effective cap − used)
        let cap_minutes: Int?                // explicit device cap; nil ⇒ effective cap = pool
    }

    /// GET /parent/earned-time/summary — child's current earned-time state.
    /// Query params: child_profile_id (required).
    func fetchEarnedSummary(childProfileID: UUID) async throws -> EarnedSummaryDTO {
        try await authedJSON(
            path: "/parent/earned-time/summary?child_profile_id=\(childProfileID.uuidString)",
            method: "GET")
    }

    /// Earned-time policy returned by GET /parent/earned-time/policy.
    struct EarnedPolicyDTO: Decodable {
        let child_profile_id: UUID?
        let list_id: String?
        let pool_minutes: Int?
        let daily_cap_minutes: Int?
        let enabled: Bool?
        let updated_at: String?
        // B9: dynamic picker option sets. Optional — only present when the
        // backend has generated the allowlists for this family's devices.
        /// Allowed per-app daily budgets for all apps on this child's devices.
        let allowed_app_options: [Int]?
        /// Per-device cap options and current cap.
        let devices: [EarnedPolicyDeviceDTO]?
    }

    /// Per-device sub-document inside EarnedPolicyDTO (B9).
    struct EarnedPolicyDeviceDTO: Decodable {
        let child_device_id: UUID?
        let device_cap_minutes: Int?
        /// Selectable cap values the UI may offer for this device.
        let allowed_cap_options: [Int]?
    }

    /// GET /parent/earned-time/policy — the family's earned-time configuration.
    func fetchEarnedPolicy(childProfileID: UUID) async throws -> EarnedPolicyDTO {
        try await authedJSON(
            path: "/parent/earned-time/policy?child_profile_id=\(childProfileID.uuidString)",
            method: "GET")
    }

    /// PUT /parent/earned-time/config — set the daily earned-time pool.
    /// Body MUST match the backend `PutPoolConfigRequest`: `daily_pool_minutes`
    /// (NOT pool_minutes), a REQUIRED `timezone`, and `effective`. The old body
    /// (pool_minutes / daily_cap_minutes / enabled, no timezone) made the backend
    /// reject every save with 422 — the pool was never persisted, so the whole
    /// earned-time pipeline (command → arm ladder → samples → bars) never started.
    /// `effective: "today"` is what makes the backend apply same-day AND emit the
    /// `earned_time_config` command so the child device arms its measurement
    /// ladder now (the default "tomorrow" writes a future row and emits nothing).
    /// Per-device cap is a SEPARATE endpoint (`putDeviceCap`), not this body.
    private struct EarnedConfigBody: Encodable {
        let child_profile_id: UUID
        let daily_pool_minutes: Int
        let timezone: String
        let effective: String
        let confirm_cascade: Bool
    }

    /// Tolerant decode of the backend's `ConfigWrittenResponse | NeedsConfirmationResponse`
    /// (both carry `status`; remaining fields are optional across the two shapes).
    struct EarnedConfigWriteResponse: Decodable {
        let status: String?
        let daily_pool_minutes: Int?
        let cap_minutes: Int?
        let command_ids: [String]?
    }

    @discardableResult
    func putEarnedConfig(
        childProfileID: UUID,
        poolMinutes: Int,
        effective: String = "today",
        confirmCascade: Bool = true
    ) async throws -> EarnedConfigWriteResponse {
        let payload = try JSONEncoder().encode(EarnedConfigBody(
            child_profile_id: childProfileID,
            daily_pool_minutes: poolMinutes,
            timezone: TimeZone.current.identifier,
            effective: effective,
            confirm_cascade: confirmCascade))
        return try await authedJSON(path: "/parent/earned-time/config", method: "PUT", jsonBody: payload)
    }

    /// PUT /parent/device/screen-time-cap — update the kid device's daily cap.
    private struct ScreenTimeCapBody: Encodable {
        let child_profile_id: UUID
        let child_device_id: UUID
        let cap_minutes: Int
        let timezone: String
        let effective: String
        let confirm_cascade: Bool
    }

    struct AffectedAppLimitDTO: Decodable {
        let rule_id: UUID
        let child_device_id: UUID
        let bundle_id: String
        let current_budget_minutes: Int
        let new_budget_minutes: Int
    }

    struct ScreenTimeCapResponseDTO: Decodable {
        let status: String?
        let cap_minutes: Int?
        let effective_date: String?
        let command_ids: [String]?
        /// Present only on the `needs_confirmation` DRY RUN — nothing was
        /// written. Callers MUST branch on `status`; treating this response as
        /// success is what made "lower the cap" silently no-op while the UI
        /// claimed the app limits had been adjusted (2026-08-07).
        let affected_app_limits: [AffectedAppLimitDTO]?

        var needsConfirmation: Bool { status == "needs_confirmation" }
    }

    @discardableResult
    static func makeDeviceCapRequestBodyData(
        childProfileID: UUID,
        childDeviceID: UUID,
        capMinutes: Int,
        timezone: String,
        effective: String,
        confirmCascade: Bool
    ) throws -> Data {
        try JSONEncoder().encode(ScreenTimeCapBody(
            child_profile_id: childProfileID,
            child_device_id: childDeviceID,
            cap_minutes: capMinutes,
            timezone: timezone,
            effective: effective,
            confirm_cascade: confirmCascade))
    }

    @discardableResult
    func putDeviceCap(
        childProfileID: UUID,
        childDeviceID: UUID,
        capMinutes: Int,
        effective: String = "today",
        confirmCascade: Bool = true
    ) async throws -> ScreenTimeCapResponseDTO {
        let payload = try Self.makeDeviceCapRequestBodyData(
            childProfileID: childProfileID,
            childDeviceID: childDeviceID,
            capMinutes: capMinutes,
            timezone: TimeZone.current.identifier,
            effective: effective,
            confirmCascade: confirmCascade)
        return try await authedJSON(path: "/parent/device/screen-time-cap", method: "PUT", jsonBody: payload)
    }

    /// POST /parent/earned-time/unlock-override — grant a one-off time extension.
    private struct UnlockOverrideBody: Encodable {
        let child_profile_id: UUID
        // REQUIRED by the backend (UnlockOverrideRequest): the exhausted day to
        // override, "yyyy-MM-dd" in the child's local tz. Omitting it 422'd every
        // exhausted-day unlock ("Couldn't unlock"). `extra_minutes` was NOT in the
        // schema (silently dead) and is dropped.
        let usage_date: String
    }

    struct UnlockOverrideResponseDTO: Decodable {
        let child_profile_id: UUID?
        let override_active: Bool?
        let updated_at: String?
    }

    @discardableResult
    func unlockOverride(childProfileID: UUID, usageDate: String) async throws -> UnlockOverrideResponseDTO {
        let payload = try JSONEncoder().encode(UnlockOverrideBody(
            child_profile_id: childProfileID,
            usage_date: usageDate))
        return try await authedJSON(path: "/parent/earned-time/unlock-override", method: "POST", jsonBody: payload)
    }

    // MARK: Per-app daily limits (P9 — DeviceAppsSheet "APP LIMITS")
    //
    // Parent CRUD over /parent/app-limits (backend child_device.py P2 routes).
    // Mirrors lockAllApps for auth/base-URL: all three go through the authed
    // layer (`authedJSON` / `authedRequest`), family resolved from the access
    // token by the backend's `get_current_family`. We STILL send `family_id` in
    // the create body (the route requires it + cross-checks it against the
    // header → 403 family_mismatch) and pass it as `family_id_q` on list/delete
    // so the same cross-check passes there too.
    //
    // Snake_case literal property names (this codebase does NOT set
    // convertFromSnakeCase on its decoder/encoder). NOTE: the backend rule id
    // field is `rule_id`, NOT `id`.

    /// One per-app limit rule. Matches the backend `AppLimitRuleResponse`.
    struct AppLimitRuleDTO: Codable, Equatable {
        let rule_id: UUID
        let family_id: UUID
        let child_device_id: UUID
        let bundle_id: String
        let display_name: String?
        let artwork_url: String?
        let daily_budget_minutes: Int
        let ordering_token: Int
        let reset_policy: String
        let window_start_minute: Int
        let window_end_minute: Int
        let timezone: String?
        let status: String
        let effective_from: Date
        let expires_at: Date?
        let updated_at: Date
        // Per-app usage bar: minutes used today. OPTIONAL so a backend that
        // predates this field (or a missing key) decodes the whole rule list
        // cleanly — read `?? 0`.
        let used_minutes: Int?
    }

    /// POST /parent/app-limits response envelope (`AppLimitRuleSetResponse`).
    private struct AppLimitRuleSetResponseDTO: Decodable {
        let rule: AppLimitRuleDTO
        let command_id: UUID
    }

    /// GET /parent/app-limits response envelope (`AppLimitRuleListResponse`).
    private struct AppLimitRuleListResponseDTO: Decodable {
        let rules: [AppLimitRuleDTO]
    }

    /// DELETE /parent/app-limits/{id} response envelope (`AppLimitRuleClearResponse`).
    private struct AppLimitRuleClearResponseDTO: Decodable {
        let rule: AppLimitRuleDTO
        let command_id: UUID
    }

    // NOTE: no `reset_policy` here — the backend `ParentAppLimitCreateRequest`
    // doesn't declare it (it's currently ignored via `extra="ignore"`, and
    // would 422 if `extra="forbid"` were ever set). v1 reset is daily by
    // default server-side. `window_start_minute`/`window_end_minute` ARE
    // accepted optionals and stay.
    private struct AppLimitCreateBody: Encodable {
        let family_id: UUID
        let child_device_id: UUID
        let bundle_id: String
        let daily_budget_minutes: Int
        let based_on_ordering_token: Int?
        let window_start_minute: Int
        let window_end_minute: Int
        // Without a timezone the backend resolves the rule's "today" as the
        // SERVER (UTC) date and the usage bar reads an empty day every US
        // evening. Always send the device's timezone.
        let timezone: String
        let display_name: String?
    }

    /// Backend rule timestamps are ISO-8601 with fractional seconds + offset
    /// (`2026-06-19T00:00:00+00:00`). A plain ISO8601DateFormatter rejects the
    /// fractional variant, so accept both.
    private static let appLimitDateDecoder: JSONDecoder = {
        let dec = JSONDecoder()
        let withFractional = ISO8601DateFormatter()
        withFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        dec.dateDecodingStrategy = .custom { decoder in
            let raw = try decoder.singleValueContainer().decode(String.self)
            if let d = withFractional.date(from: raw) ?? plain.date(from: raw) { return d }
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath,
                      debugDescription: "Unrecognized app-limit date: \(raw)"))
        }
        return dec
    }()

    private func authedJSONAppLimit<T: Decodable>(
        path: String, method: String, jsonBody: Data? = nil
    ) async throws -> T {
        var req = authedRequest(path: path, method: method)
        if let jsonBody { req.httpBody = jsonBody }
        let (data, http) = try await authedData(for: req)
        guard (200..<300).contains(http.statusCode) else {
            throw APIError.serverError(http.statusCode)
        }
        return try Self.appLimitDateDecoder.decode(T.self, from: data)
    }

    /// POST /parent/app-limits — create-or-update the daily time limit for one
    /// app (by bundle id) on the kid device, then emit a set_limit command.
    /// v1 always uses the whole-day window 00:00–23:59 with a daily reset.
    @discardableResult
    func setAppLimit(
        familyID: UUID,
        childDeviceID: UUID,
        bundleID: String,
        dailyBudgetMinutes: Int,
        basedOnOrderingToken: Int? = nil,
        displayName: String? = nil
    ) async throws -> AppLimitRuleDTO {
        let body = AppLimitCreateBody(
            family_id: familyID,
            child_device_id: childDeviceID,
            bundle_id: bundleID,
            daily_budget_minutes: dailyBudgetMinutes,
            based_on_ordering_token: basedOnOrderingToken,
            window_start_minute: 0,
            window_end_minute: 1439,
            timezone: TimeZone.current.identifier,
            display_name: displayName
        )
        let payload = try JSONEncoder().encode(body)
        let envelope: AppLimitRuleSetResponseDTO = try await authedJSONAppLimit(
            path: "/parent/app-limits", method: "POST", jsonBody: payload)
        return envelope.rule
    }

    /// DELETE /parent/app-limits/{rule_id} — disable the rule and emit a
    /// clear_limit command. `familyID` is sent as `family_id_q` for the
    /// backend's header/body family cross-check.
    @discardableResult
    func clearAppLimit(familyID: UUID, ruleID: UUID) async throws -> AppLimitRuleDTO {
        var comps = URLComponents()
        comps.path = "/parent/app-limits/\(ruleID.uuidString)"
        comps.queryItems = [URLQueryItem(name: "family_id_q", value: familyID.uuidString)]
        let path = comps.string ?? "/parent/app-limits/\(ruleID.uuidString)"
        let envelope: AppLimitRuleClearResponseDTO = try await authedJSONAppLimit(
            path: path, method: "DELETE")
        return envelope.rule
    }

    /// GET /parent/app-limits?child_device_id=&family_id_q= — active rules for a
    /// child device. Family resolved from auth; `family_id_q` cross-checks it.
    func listAppLimits(familyID: UUID, childDeviceID: UUID) async throws -> [AppLimitRuleDTO] {
        var comps = URLComponents()
        comps.path = "/parent/app-limits"
        comps.queryItems = [
            URLQueryItem(name: "child_device_id", value: childDeviceID.uuidString),
            URLQueryItem(name: "family_id_q", value: familyID.uuidString),
        ]
        let path = comps.string ?? "/parent/app-limits?child_device_id=\(childDeviceID.uuidString)"
        // A per-app rule can be disabled and recreated with a new budget in the
        // same minute. This screen is a live control surface, so a cached list
        // can show the disabled predecessor (for example 15/20 after 15/30
        // became authoritative). Always fetch the current active-rule view.
        var request = authedRequest(path: path, method: "GET")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, http) = try await authedData(for: request)
        guard (200..<300).contains(http.statusCode) else {
            throw APIError.serverError(http.statusCode)
        }
        let envelope = try Self.appLimitDateDecoder.decode(
            AppLimitRuleListResponseDTO.self,
            from: data
        )
        return envelope.rules
    }
}

// MARK: - App-alias management (Task F1)
//
// Parent CRUD over /parent/app-aliases. Mirrors the AliasManagingClient pattern:
// protocol declared here, methods in `extension APIClient`, conformance via
// `extension APIClient: AppAliasManagingClient {}`.

protocol AppAliasManagingClient {
    /// GET /parent/app-aliases?family_id= — all family apps with their aliases
    /// and the child devices that can receive a lock command for each.
    func fetchAppAliases(familyID: UUID) async throws -> [AppAliasRow]

    /// GET /parent/child-devices?family_id= — all child devices in the family.
    func fetchParentChildDevices(familyID: UUID) async throws -> [ParentChildDeviceSummaryDTO]

    /// POST /parent/app-aliases/{bundleID}/alias — add an alias to an app.
    func addAppAlias(familyID: UUID, bundleID: String, alias: String) async throws

    /// DELETE /parent/app-aliases/{bundleID}/alias?family_id=&alias= — remove an alias.
    func removeAppAlias(familyID: UUID, bundleID: String, alias: String) async throws

    /// PATCH /parent/app-aliases/{bundleID}/alias — rename an alias.
    func renameAppAlias(familyID: UUID, bundleID: String, old: String, new: String) async throws
}

extension APIClient {
    func fetchAppAliases(familyID: UUID) async throws -> [AppAliasRow] {
        var comps = URLComponents(string: "\(baseURL)/parent/app-aliases")!
        comps.queryItems = [URLQueryItem(name: "family_id", value: familyID.uuidString)]
        // Force a fresh fetch — `data(from:url)` uses `.useProtocolCachePolicy`, so a
        // pull-to-refresh can be served a STALE cached response (the symptom: the list
        // only updates after leaving + re-entering). Bypass the URL cache.
        var req = URLRequest(url: comps.url!)
        req.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
            throw APIError.serverError((resp as? HTTPURLResponse)?.statusCode ?? 0)
        }
        return try JSONDecoder().decode(AppAliasFeedResponse.self, from: data).apps
    }

    func addAppAlias(familyID: UUID, bundleID: String, alias: String) async throws {
        let encoded = Self.pathComponent(bundleID)
        let url = URL(string: "\(baseURL)/parent/app-aliases/\(encoded)/alias")!
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 22
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        struct Body: Encodable {
            let alias: String
            let family_id: UUID
        }
        req.httpBody = try JSONEncoder().encode(Body(alias: alias, family_id: familyID))
        let (_, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
            throw APIError.serverError((resp as? HTTPURLResponse)?.statusCode ?? 0)
        }
    }

    func removeAppAlias(familyID: UUID, bundleID: String, alias: String) async throws {
        let encoded = Self.pathComponent(bundleID)
        var comps = URLComponents(string: "\(baseURL)/parent/app-aliases/\(encoded)/alias")!
        comps.queryItems = [
            URLQueryItem(name: "family_id", value: familyID.uuidString),
            URLQueryItem(name: "alias", value: alias),
        ]
        var req = URLRequest(url: comps.url!)
        req.httpMethod = "DELETE"
        req.timeoutInterval = 22
        let (_, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
            throw APIError.serverError((resp as? HTTPURLResponse)?.statusCode ?? 0)
        }
    }

    func renameAppAlias(familyID: UUID, bundleID: String, old: String, new: String) async throws {
        let encoded = Self.pathComponent(bundleID)
        let url = URL(string: "\(baseURL)/parent/app-aliases/\(encoded)/alias")!
        var req = URLRequest(url: url)
        req.httpMethod = "PATCH"
        req.timeoutInterval = 22
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        struct Body: Encodable {
            let old: String
            let new: String
            let family_id: UUID
        }
        req.httpBody = try JSONEncoder().encode(Body(old: old, new: new, family_id: familyID))
        let (_, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
            throw APIError.serverError((resp as? HTTPURLResponse)?.statusCode ?? 0)
        }
    }
}

extension APIClient: AppAliasManagingClient {}

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
    /// POST /parent/chat/title — ask the backend to name a conversation from its
    /// first message (ChatGPT-style). Stateless; the caller decides whether to
    /// apply it. Throws on network/auth/decode failure so the caller can keep
    /// its existing fallback title.
    func generateConversationTitle(firstMessage: String) async throws -> String {
        var req = authedRequest(path: "/parent/chat/title", method: "POST")
        req.httpBody = try JSONEncoder().encode(["message": firstMessage])
        let (data, http) = try await authedData(for: req)
        guard http.statusCode == 200 else { throw AuthError.http(http.statusCode) }
        struct TitleResponse: Decodable { let title: String }
        return try JSONDecoder().decode(TitleResponse.self, from: data).title
    }

    /// Public seam over the §14.7 single-flight refresher so the streaming
    /// client reuses the SAME refresh lock instead of building a second one.
    func refreshAccessTokenSingleFlight() async throws -> String {
        try await Self.sharedRefresher.refreshedToken()
    }

    func authedRequest(
        path: String,
        method: String = "GET",
        timeoutInterval: TimeInterval? = nil
    ) -> URLRequest {
        let url = URL(string: "\(baseURL)\(path)")!
        var req = URLRequest(url: url)
        req.httpMethod = method
        if let timeoutInterval {
            // Parent actions must surface a recoverable error instead of leaving
            // their controls indefinitely busy when a backend connection stalls.
            req.timeoutInterval = timeoutInterval
        }
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
        } catch AuthError.signedOut {
            // Terminal auth failure ONLY (invalid/expired/reused refresh token, or
            // no stored session). Transient failures — network blips, 5xx, Render
            // cold starts — propagate WITHOUT clearing the Keychain, so a hiccup
            // can't sign the user out mid-onboarding.
            KeychainStore.shared.clear()
            NotificationCenter.default.post(name: .evlinSessionSignedOut, object: nil)
            throw AuthError.signedOut
        }
    }

    /// The process-wide single-flight refresher. Its work closure calls
    /// POST /auth/refresh with the stored refresh token and atomically rewrites
    /// the Keychain with the rotated tokens (§14.7).
    static let sharedRefresher = SingleFlightRefresher {
        // P1-C3: only a GENUINELY ABSENT session is a terminal sign-out. A
        // temporarily unreadable Keychain (e.g. locked before first unlock) must
        // surface as a transient error — throwing `.signedOut` here used to make
        // `authedData` CLEAR a perfectly valid session and force re-login.
        let current: StoredTokens
        switch KeychainStore.shared.loadResult() {
        case .found(let tokens):
            current = tokens
        case .notFound:
            throw APIClient.AuthError.signedOut
        case .unreadable(let status):
            throw APIClient.AuthError.http(Int(status))
        }
        let base = APIClient.currentBaseURL
        let url = URL(string: "\(base)/auth/refresh")!
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(["refresh_token": current.refreshToken])
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else {
            throw APIClient.AuthError.http(-1)
        }
        guard http.statusCode == 200 else {
            // Only an explicit 401 (invalid/expired/reused refresh token) is
            // terminal → sign out. 5xx / other statuses are transient (cold start,
            // blip) and must NOT clear the session, or a flaky backend logs the
            // user out. They surface as `.http` and propagate (no signout).
            if http.statusCode == 401 { throw APIClient.AuthError.signedOut }
            throw APIClient.AuthError.http(http.statusCode)
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
