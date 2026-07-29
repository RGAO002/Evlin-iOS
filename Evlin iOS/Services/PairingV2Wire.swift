import Foundation

/// Wire contract for parent-mediated pairing v2 (`/family/v2/*`).
///
/// Spec: Evlin-Backend/docs/superpowers/specs/2026-07-28-pairing-v2-design.md
/// Plan: Evlin-Backend/docs/superpowers/plans/2026-07-28-pairing-v2.md (Task 1)
///
/// The legacy pairing flow (kid mints the code, parent scans it) is untouched;
/// nothing in this file is referenced by it.

extension JSONDecoder.DateDecodingStrategy {

    /// Pydantic v2 serializes datetimes with microseconds
    /// (`2026-07-29T05:12:55.815296+00:00`), and Swift's stock `.iso8601` is
    /// strict enough to reject fractional seconds outright — the decode throws
    /// and the caller sees a generic failure with no hint that the server was
    /// fine all along. Try the fractional variant, then plain.
    ///
    /// `JSONDecoder.bigKid` carries its own copy of this from an earlier
    /// encounter with the same trap; it also applies key conversion, which
    /// would fight the explicit snake_case CodingKeys used here.
    static let evlinBackendISO8601 = JSONDecoder.DateDecodingStrategy.custom { decoder in
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: raw) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        if let date = plain.date(from: raw) { return date }
        throw DecodingError.dataCorruptedError(
            in: container,
            debugDescription: "Expected ISO 8601 date, got \(raw)"
        )
    }
}

extension JSONDecoder {
    /// Decoder for every `/family/v2` response. The DTOs declare their own
    /// snake_case keys, so no key strategy is applied.
    static let pairingV2: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .evlinBackendISO8601
        return d
    }()
}

nonisolated enum PairingInvitePurpose: String, Codable, Sendable {
    case newChild = "new_child"
    case addDevice = "add_device"
}

/// Which identity the kid device is adopting. `restore` reuses the device row
/// this hardware already had in that family; `invited` takes whatever the
/// invite offers (a new child, or an existing one for add-device).
nonisolated enum AdoptionChoice: String, Codable, Sendable {
    case restore
    case invited
}

nonisolated struct PairingInvitedInfo: Codable, Equatable, Sendable {
    let purpose: PairingInvitePurpose
    /// Present only for add-device, and only ever ONE name — the parent picked
    /// the target when minting, so an unauthenticated device never sees the
    /// family roster.
    let childDisplayName: String?

    enum CodingKeys: String, CodingKey {
        case purpose
        case childDisplayName = "child_display_name"
    }
}

nonisolated struct PairingRestoreInfo: Codable, Equatable, Sendable {
    let childDisplayName: String

    enum CodingKeys: String, CodingKey {
        case childDisplayName = "child_display_name"
    }
}

nonisolated struct PairingResolveResponse: Codable, Equatable, Sendable {
    let resolveSession: String
    let invited: PairingInvitedInfo
    /// Non-nil when this hardware already has an identity in the inviting
    /// family — the UI offers "restore" before falling back to `invited`.
    let restore: PairingRestoreInfo?

    enum CodingKeys: String, CodingKey {
        case resolveSession = "resolve_session"
        case invited
        case restore
    }
}

nonisolated struct PairingNewChildProfile: Codable, Equatable, Sendable {
    let displayName: String
    let birthYear: Int?
    let gender: String?

    enum CodingKeys: String, CodingKey {
        case displayName = "display_name"
        case birthYear = "birth_year"
        case gender
    }
}

/// Authentication material for the post-adoption bootstrap. `resolveSession`
/// is consumed by the commit and must never be reused as a device credential,
/// so the server hands this back instead. The child lane is still X-Child-Id
/// self-declaration (FIX-K placeholder) — the field exists so FIX-K can change
/// what is inside without another protocol revision.
nonisolated struct PairingDeviceCredential: Codable, Equatable, Sendable {
    let scheme: String
    let childDeviceID: UUID

    enum CodingKeys: String, CodingKey {
        case scheme
        case childDeviceID = "child_device_id"
    }
}

nonisolated struct PairingCommitResult: Codable, Equatable, Sendable {
    let familyID: UUID
    let childDeviceID: UUID
    let childProfileID: UUID
    /// How the identity was obtained: "restore" or "invited". NOT the device
    /// mode (which is always child on this path).
    let mode: String
    let deviceCredential: PairingDeviceCredential

    enum CodingKeys: String, CodingKey {
        case familyID = "family_id"
        case childDeviceID = "child_device_id"
        case childProfileID = "child_profile_id"
        case mode
        case deviceCredential = "device_credential"
    }
}

// MARK: - Parent side

nonisolated struct PairingInviteCreated: Codable, Equatable, Sendable {
    let inviteID: UUID
    /// Six digits, for when the camera is unusable.
    let codeDisplay: String
    /// Carries the scheme prefix; render verbatim into the QR image.
    let qrPayload: String
    let expiresAt: Date

    enum CodingKeys: String, CodingKey {
        case inviteID = "invite_id"
        case codeDisplay = "code_display"
        case qrPayload = "qr_payload"
        case expiresAt = "expires_at"
    }
}

nonisolated struct PairingInviteStatus: Codable, Equatable, Sendable {
    /// "pending" | "joined" | "expired"
    let status: String
    let childDisplayName: String?
    let deviceLabel: String?
    /// Which branch the kid device took: "restore" or "invited".
    let resolution: String?

    enum CodingKeys: String, CodingKey {
        case status
        case childDisplayName = "child_display_name"
        case deviceLabel = "device_label"
        case resolution
    }
}

/// What the scanner (or the typed-code field) produced.
///
/// The backend mints QR payloads with a fixed scheme prefix precisely so this
/// decision has one source of truth: a bare token would otherwise be
/// indistinguishable from a typed code and get posted to the wrong field.
nonisolated enum ScannedInvite: Equatable, Sendable {
    case legacySixDigit(String)
    case v2Token(String)

    static let scheme = "evlin-invite:v2:"

    static func parse(_ raw: String) -> ScannedInvite? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix(scheme) {
            let token = String(trimmed.dropFirst(scheme.count))
            return token.isEmpty ? nil : .v2Token(token)
        }
        if trimmed.count == 6, trimmed.allSatisfy(\.isNumber) {
            return .legacySixDigit(trimmed)
        }
        return nil
    }
}
