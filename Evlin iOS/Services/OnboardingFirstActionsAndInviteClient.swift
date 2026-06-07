import Foundation

// Onboarding v2 — APIClient methods for Plan 5 (co-parent invites) and Plan 7
// (first-actions real lock + reflection payoff). Kept in a dedicated extension
// file so the large `APIClient.swift` stays untouched. Every DTO/shape here is
// matched against the live backend routes:
//   * Plan 5 invite endpoints — app/api/routes/family.py (authed: 🔑/👪).
//   * Plan 7 lock/reflection endpoints — app/api/routes/child_device.py
//     (/parent/child-app-catalog/lock) + bigkid_parent.py
//     (/parent/reflection/trigger, /parent/state/{child_id}) + bigkid_child.py
//     (/child/reflection/{rid}/lock-applied). These parent/kid bigkid routes are
//     UNauthed in this build (they take no get_current_family dep), so they go
//     over a bare URLSession — NOT the authed Bearer layer.

// MARK: - Plan 5 co-parent invite DTOs (owner Settings management)
//
// `ConsumeInviteResponseDTO`, `PendingInviteDTO`, `FamilyMeResponseDTO` already
// exist in APIClient.swift and are REUSED — not redeclared here.

/// POST /family/invite — MintInviteResponse.
struct MintInviteDTO: Decodable, Sendable, Equatable {
    let code: String
    let expiresAt: Date
    let shareText: String
    enum CodingKeys: String, CodingKey {
        case code
        case expiresAt = "expires_at"
        case shareText = "share_text"
    }
}

/// One row of GET /family/invite — InviteSummary.
struct InviteSummaryDTO: Decodable, Sendable, Equatable, Identifiable {
    var id: String { code }
    let code: String
    let expiresAt: Date
    let consumedAt: Date?
    let approvalStatus: String?
    enum CodingKeys: String, CodingKey {
        case code
        case expiresAt = "expires_at"
        case consumedAt = "consumed_at"
        case approvalStatus = "approval_status"
    }
}

/// GET /family/invite — ListInvitesResponse.
struct ListInvitesDTO: Decodable, Sendable, Equatable {
    let invites: [InviteSummaryDTO]
}

/// POST /family/invite/{code}/approve — ApproveInviteResponse.
struct ApproveInviteDTO: Decodable, Sendable, Equatable {
    let ok: Bool
    let status: String   // "approved" | "declined"
}

/// Typed invite errors mapped from the backend `detail` strings so the owner /
/// join UI can render specific copy instead of a bare status code.
enum CoParentInviteError: Error, Equatable {
    case notOwner          // 403 not_owner
    case alreadyInFamily   // 409 already_in_family
    case capReached        // 409 invite_cap_reached
    case inviteInvalid     // 404 invite_invalid
    case rateLimited       // 429 rate_limited
    case notPending        // 409 not_pending
    case http(Int)
}

// MARK: - Plan 7 first-actions targets

/// The resolved block target the catalog-lock call sends. `appID` maps to the
/// kid's first real catalog app (alias_key → backend `app_id`); `appName` maps
/// to a category/by-name fallback (backend `app_name`, e.g. "Games"/"TikTok").
enum FirstBlockTarget: Equatable, Sendable {
    case appID(UUID)
    case appName(String)
}

// MARK: - Plan 8 device-register DTO (returning-parent recovery)

/// POST /family/device/register — DeviceRegisterResponse (app/api/routes/family.py).
struct DeviceRegisterResponseDTO: Decodable, Sendable, Equatable {
    let device_id: UUID
    let family_id: UUID
    let mode: String          // "parent" | "child" (DeviceMode)
    let created: Bool
}

extension APIClient {

    // MARK: - Plan 5: co-parent invites (owner-side, authed)
    //
    // These reuse the SAME authed layer (`authedRequest` + `authedData` single-
    // flight 401 refresh, §14.7) the rest of the v2 parent surfaces use — so the
    // owner Settings view does not hand-build Bearer headers.

    private func decodeInviteDetail(_ data: Data) -> String? {
        (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["detail"] as? String
    }

    private func mapInviteError(_ status: Int, _ data: Data) -> CoParentInviteError {
        switch (status, decodeInviteDetail(data)) {
        case (403, "not_owner"):          return .notOwner
        case (409, "already_in_family"):  return .alreadyInFamily
        case (409, "invite_cap_reached"): return .capReached
        case (409, "not_pending"):        return .notPending
        case (404, _):                    return .inviteInvalid
        case (429, _):                    return .rateLimited
        default:                          return .http(status)
        }
    }

    /// JSON decoder for invite responses. The backend (Pydantic v2 / Postgres
    /// `func.now()`) serializes timestamps WITH fractional seconds
    /// (`2026-06-13T00:00:00.123456+00:00`), which Swift's strict `.iso8601`
    /// rejects — so we use the fractional-seconds-tolerant strategy (try
    /// fractional first, fall back to plain), mirroring `JSONDecoder.bigKid`.
    private func inviteDecoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let str = try container.decode(String.self)
            let withFraction = ISO8601DateFormatter()
            withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = withFraction.date(from: str) { return date }
            let plain = ISO8601DateFormatter()
            plain.formatOptions = [.withInternetDateTime]
            if let date = plain.date(from: str) { return date }
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Expected ISO 8601 date, got \(str)"
            )
        }
        return d
    }

    /// POST /family/invite — OWNER mints a co-parent invite. 👪 owner-only;
    /// 403 not_owner / 409 invite_cap_reached surface as typed errors.
    func mintInvite() async throws -> MintInviteDTO {
        var req = authedRequest(path: "/family/invite", method: "POST")
        req.httpBody = Data("{}".utf8)
        let (data, http) = try await authedData(for: req)
        guard (200..<300).contains(http.statusCode) else {
            throw mapInviteError(http.statusCode, data)
        }
        return try inviteDecoder().decode(MintInviteDTO.self, from: data)
    }

    /// GET /family/invite — list this family's invites (owner-side).
    func listInvites() async throws -> [InviteSummaryDTO] {
        let req = authedRequest(path: "/family/invite", method: "GET")
        let (data, http) = try await authedData(for: req)
        guard (200..<300).contains(http.statusCode) else {
            throw mapInviteError(http.statusCode, data)
        }
        return try inviteDecoder().decode(ListInvitesDTO.self, from: data).invites
    }

    /// POST /family/invite/{code}/approve — owner approves/declines a pending
    /// consumer. `decision` is "approve" | "decline". On approve the backend
    /// binds the co-parent's family_id + role=parent.
    @discardableResult
    func approveInvite(code: String, decision: String) async throws -> ApproveInviteDTO {
        var req = authedRequest(path: "/family/invite/\(code)/approve", method: "POST")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["decision": decision])
        let (data, http) = try await authedData(for: req)
        guard (200..<300).contains(http.statusCode) else {
            throw mapInviteError(http.statusCode, data)
        }
        return try inviteDecoder().decode(ApproveInviteDTO.self, from: data)
    }

    /// DELETE /family/invite/{code} — owner revokes an invite (204).
    func revokeInvite(code: String) async throws {
        let req = authedRequest(path: "/family/invite/\(code)", method: "DELETE")
        let (data, http) = try await authedData(for: req)
        guard http.statusCode == 204 || (200..<300).contains(http.statusCode) else {
            throw mapInviteError(http.statusCode, data)
        }
    }

    // MARK: - Plan 8: returning-parent device recovery (authed)

    /// POST /family/device/register — register THIS device as a parent device on
    /// the account's already-bound family (idempotent upsert on the X-Device-Id
    /// header, §1.7). The SINGLE authed path for a returning parent on a new
    /// device or an approved co-parent to (re)attach a device WITHOUT consuming a
    /// kid pairing code. Sends the persistent `deviceID` as `X-Device-Id` + the
    /// device hardware fields.
    @discardableResult
    func registerParentDevice(deviceID: UUID, label: String) async throws -> DeviceRegisterResponseDTO {
        var req = authedRequest(path: "/family/device/register", method: "POST")
        req.setValue(deviceID.uuidString, forHTTPHeaderField: "X-Device-Id")
        let info = DeviceInfoProvider.current()
        let body: [String: Any] = [
            "label": label,
            "device_model": info.device_model,
            "device_model_id": info.device_model_id,
            "platform": info.platform,
            "os_version": info.os_version,
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, http) = try await authedData(for: req)
        guard (200..<300).contains(http.statusCode) else {
            throw APIError.serverError(http.statusCode)
        }
        return try JSONDecoder().decode(DeviceRegisterResponseDTO.self, from: data)
    }

    // MARK: - Plan 7: first-actions (real lock + reflection payoff)
    //
    // §8: the parent's first onboarding "block" + "reflection" run against the
    // child DEVICE id (§1.1). The /parent/child-app-catalog/lock route guards on
    // the in-body `family_id`/`child_device_id` (UNauthed in this build), so the
    // block call sends both. The reflection trigger + parent/state + kid
    // lock-applied are likewise UNauthed (X-Child-Id for the kid call).

    /// Onboarding Action 1: queue a real timed app-block via
    /// POST /parent/child-app-catalog/lock. Send exactly ONE of `appID`
    /// (alias_key → `app_id`) / `appName` (category/by-name → `app_name`).
    /// Returns the `command_id` to poll via `fetchRichAckStatus`.
    /// Throws `APIError.serverError(422)` when an `app_name` is unresolved
    /// (caller escalates the fallback chain).
    func queueOnboardingAppBlock(
        familyID: UUID,
        childDeviceID: UUID,
        target: FirstBlockTarget,
        durationMinutes: Int = 5
    ) async throws -> UUID {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let url = URL(string: "\(trimmed)/parent/child-app-catalog/lock")
        else { throw URLError(.badURL) }
        var body: [String: Any] = [
            "family_id": familyID.uuidString,
            "child_device_id": childDeviceID.uuidString,
            "duration_minutes": durationMinutes,
        ]
        switch target {
        case .appID(let aliasKey): body["app_id"] = aliasKey.uuidString
        case .appName(let name):   body["app_name"] = name
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 28
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
            throw APIError.serverError((resp as? HTTPURLResponse)?.statusCode ?? 0)
        }
        struct LockResponse: Decodable { let command_id: UUID }
        return try JSONDecoder().decode(LockResponse.self, from: data).command_id
    }

    /// Onboarding Action 2: trigger a state-derived all-apps reflection via
    /// POST /parent/reflection/trigger with the §14.1 first-run short-cap so a
    /// missed exit/background auto-cancel can never brick the kid for 2h. Keyed
    /// on the child DEVICE id (§1.1). Returns the reflection id (rid).
    func triggerOnboardingReflection(
        childDeviceID: UUID,
        reason: String = "Let's try Reflection together",
        onboardingCapSeconds: Int = 180
    ) async throws -> UUID {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let url = URL(string: "\(trimmed)/parent/reflection/trigger")
        else { throw URLError(.badURL) }
        let body: [String: Any] = [
            "child_id": childDeviceID.uuidString,
            "reason": reason,
            "onboarding_cap_seconds": onboardingCapSeconds,
            "onboarding_test": true,
        ]
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 28
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
            throw APIError.serverError((resp as? HTTPURLResponse)?.statusCode ?? 0)
        }
        struct TriggerResponse: Decodable { let id: UUID }
        return try JSONDecoder().decode(TriggerResponse.self, from: data).id
    }

    /// Onboarding Action 2 payoff poll: GET /parent/state/{child_id} and decode
    /// the parent-side child state. The caller reads
    /// `reflectionRequest.lockAppliedAt` (the honest "kid applied the lock"
    /// signal, §8.1). Child DEVICE id in the path.
    func fetchParentChildState(childDeviceID: UUID) async throws -> ChildStateResponse {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let url = URL(string: "\(trimmed)/parent/state/\(childDeviceID.uuidString)")
        else { throw URLError(.badURL) }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.timeoutInterval = 22
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
            throw APIError.serverError((resp as? HTTPURLResponse)?.statusCode ?? 0)
        }
        return try JSONDecoder.bigKid.decode(ChildStateResponse.self, from: data)
    }

    /// §8.1 first-sight hook: the kid device confirms it APPLIED the all-apps
    /// reflection lock. Kid-scoped — `X-Child-Id` = child DEVICE id (§1.1),
    /// matching the trigger. Best-effort; idempotent 204 server-side.
    func postReflectionLockApplied(childDeviceID: UUID, reflectionID: UUID) async throws {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let url = URL(string: "\(trimmed)/child/reflection/\(reflectionID.uuidString)/lock-applied")
        else { throw URLError(.badURL) }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 12
        req.setValue(childDeviceID.uuidString, forHTTPHeaderField: "X-Child-Id")
        let (_, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
            throw APIError.serverError((resp as? HTTPURLResponse)?.statusCode ?? 0)
        }
    }
}
