import Foundation

nonisolated struct PairingV2ClientError: Error, Equatable {
    let statusCode: Int
}

/// HTTP client for `/family/v2/*`.
///
/// Unauthenticated on purpose: the kid device has no session until it commits,
/// and the invite token is the only thing authorizing the call.
nonisolated final class PairingV2Client: @unchecked Sendable {

    private let baseURL: URL
    private let session: URLSession

    init(baseURL: URL, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
    }

    /// Production instance pointed at whatever backend this build talks to.
    static func production() -> PairingV2Client? {
        guard let url = URL(string: APIClient.currentBaseURL) else { return nil }
        return PairingV2Client(baseURL: url)
    }

    private func post(_ path: String, body: [String: Any]) async throws -> Data {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await session.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200...299).contains(code) else {
            throw PairingV2ClientError(statusCode: code)
        }
        return data
    }

    // MARK: - Resolve

    /// A scanned token and a typed code go to DIFFERENT fields. Posting a
    /// six-digit code as `token` would hash to nothing and always 404, so the
    /// enum decides rather than the caller.
    static func resolveBody(invite: ScannedInvite,
                            device: [String: String]) -> [String: Any] {
        var body: [String: Any] = ["device": device]
        switch invite {
        case .v2Token(let token):
            body["token"] = token
        case .legacySixDigit(let code):
            body["code"] = code
        }
        return body
    }

    func resolve(_ invite: ScannedInvite,
                 device: [String: String]) async throws -> PairingResolveResponse {
        let data = try await post("family/v2/join/resolve",
                                  body: Self.resolveBody(invite: invite,
                                                         device: device))
        return try JSONDecoder().decode(PairingResolveResponse.self, from: data)
    }

    // MARK: - Commit

    static func makeCommitRecord(
        inviteID: UUID?,
        resolveSession: String,
        choice: AdoptionChoice,
        profile: PairingNewChildProfile?,
        device: [String: String],
        oldUUID: UUID?
    ) -> PendingAdoptionRecord {
        PendingAdoptionRecord(
            inviteID: inviteID,
            resolveSession: resolveSession,
            choice: choice,
            oldUUID: oldUUID,
            profile: profile,
            deviceSnapshot: device
        )
    }

    /// The ONLY place a commit body is built.
    ///
    /// The server compares a digest of choice+profile and a hash of the device
    /// fields before returning a replayed result, so the first attempt and any
    /// later retry have to produce the same body. Deriving it purely from the
    /// stored record — never from live state — is what makes that true across
    /// a relaunch.
    static func commitBody(from record: PendingAdoptionRecord) -> [String: Any] {
        var body: [String: Any] = [
            "resolve_session": record.resolveSession,
            "commit_request_id": record.commitRequestID.uuidString,
            "choice": record.choice.rawValue,
            "device": record.deviceSnapshot,
        ]
        if let profile = record.profile {
            var encoded: [String: Any] = ["display_name": profile.displayName]
            if let year = profile.birthYear { encoded["birth_year"] = year }
            if let gender = profile.gender { encoded["gender"] = gender }
            body["profile"] = encoded
        }
        return body
    }

    /// Commit, or replay a commit whose response was lost.
    ///
    /// The record is persisted BEFORE the request goes out. Without that, a
    /// response lost in flight leaves the server holding a consumed invite and
    /// the device holding nothing — no identity, and no way to ask for the
    /// result again.
    func commit(record: PendingAdoptionRecord,
                store: PendingAdoptionStore) async throws -> PairingCommitResult {
        if let alreadyDone = record.result {
            return alreadyDone
        }
        var pending = record
        try store.save(pending)

        let data = try await post("family/v2/join/commit",
                                  body: Self.commitBody(from: pending))
        let result = try JSONDecoder().decode(PairingCommitResult.self, from: data)
        pending.result = result
        try store.save(pending)
        return result
    }
}
