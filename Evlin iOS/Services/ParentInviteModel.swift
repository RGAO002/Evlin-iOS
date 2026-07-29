import Combine
import Foundation

/// What the parent's invite screen should be showing.
nonisolated enum ParentInviteStage: Equatable, Sendable {
    case idle
    case minting
    case showing(PairingInviteCreated)
    /// The kid device finished joining; `resolution` says which branch it took.
    case joined(childName: String?, deviceLabel: String?, resolution: String?)
    case expired
    case failed(message: String)
}

/// Network seam. Injected so the model's polling and stage transitions are
/// testable without a server, and so the real implementation can reuse
/// `APIClient`'s authenticated request path (single-flight refresh included)
/// rather than growing a second copy of token handling.
nonisolated struct ParentInviteAPI: Sendable {
    let ensureFamily: @Sendable () async throws -> Void
    let createInvite: @Sendable (PairingInvitePurpose, UUID?) async throws -> PairingInviteCreated
    let fetchStatus: @Sendable (UUID) async throws -> PairingInviteStatus
}

@MainActor
final class ParentInviteModel: ObservableObject {

    @Published private(set) var stage: ParentInviteStage = .idle

    /// Settable so the host can inject the environment's `APIClient` after
    /// construction: a `@StateObject` initializer cannot reach an
    /// `@EnvironmentObject`, and building a second APIClient just to satisfy
    /// the initializer would re-run its base-URL side effects.
    var api: ParentInviteAPI
    private let pollInterval: Duration
    private var pollTask: Task<Void, Never>?

    /// Called once the kid device has joined, so the host flow can advance.
    var onJoined: (() -> Void)?
    /// Fired as soon as a code exists. Single-device demo uses it to hand the
    /// code to the kid half of the same phone; the two-device flow ignores it.
    var onCodeReady: ((PairingInviteCreated) -> Void)?

    init(api: ParentInviteAPI = .unconfigured,
         pollInterval: Duration = .seconds(2)) {
        self.api = api
        self.pollInterval = pollInterval
    }

    deinit { pollTask?.cancel() }

    /// Maps a status response to a stage. Kept separate and pure so the
    /// mapping is testable without driving the polling loop.
    nonisolated static func stage(
        for status: PairingInviteStatus,
        showing invite: PairingInviteCreated
    ) -> ParentInviteStage {
        switch status.status {
        case "joined":
            return .joined(childName: status.childDisplayName,
                           deviceLabel: status.deviceLabel,
                           resolution: status.resolution)
        case "expired":
            return .expired
        default:
            return .showing(invite)
        }
    }

    func mint(purpose: PairingInvitePurpose, target: UUID?) async {
        stage = .minting
        do {
            // Idempotent: a family born on the parent's account is the anchor
            // the whole flow hangs off, and the endpoint returns the existing
            // one when there already is one.
            try await api.ensureFamily()
            let invite = try await api.createInvite(purpose, target)
            stage = .showing(invite)
            onCodeReady?(invite)
            startPolling(invite: invite)
        } catch {
            stage = .failed(message: "Couldn't create a code. Check your connection and try again.")
        }
    }

    func startPolling(invite: PairingInviteCreated) {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: self.pollInterval)
                if Task.isCancelled { return }
                guard let status = try? await self.api.fetchStatus(invite.inviteID)
                else { continue }   // a blip must not kill the watch
                let next = Self.stage(for: status, showing: invite)
                self.stage = next
                if case .joined = next {
                    self.onJoined?()
                    return
                }
                if case .expired = next { return }
            }
        }
    }

    func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }
}

// MARK: - Production API

extension ParentInviteAPI {

    /// Placeholder until the host injects the real client. Every call fails
    /// loudly rather than silently succeeding, so a missing injection shows up
    /// as "couldn't create a code" instead of a screen that never advances.
    static let unconfigured = ParentInviteAPI(
        ensureFamily: { throw PairingV2ClientError(statusCode: -1) },
        createInvite: { _, _ in throw PairingV2ClientError(statusCode: -1) },
        fetchStatus: { _ in throw PairingV2ClientError(statusCode: -1) }
    )

    /// Live implementation over `APIClient`'s authed request path.
    static func live(client: APIClient) -> ParentInviteAPI {
        return ParentInviteAPI(
            ensureFamily: {
                let request = client.authedRequest(path: "/family/v2", method: "POST")
                let (_, http) = try await client.authedData(for: request)
                guard (200...299).contains(http.statusCode) else {
                    throw PairingV2ClientError(statusCode: http.statusCode)
                }
            },
            createInvite: { purpose, target in
                var request = client.authedRequest(path: "/family/v2/invite",
                                                   method: "POST")
                var body: [String: Any] = ["purpose": purpose.rawValue]
                if let target { body["target_child_profile_id"] = target.uuidString }
                request.httpBody = try JSONSerialization.data(withJSONObject: body)
                let (data, http) = try await client.authedData(for: request)
                guard (200...299).contains(http.statusCode) else {
                    throw PairingV2ClientError(statusCode: http.statusCode)
                }
                return try JSONDecoder.pairingV2.decode(PairingInviteCreated.self, from: data)
            },
            fetchStatus: { inviteID in
                let request = client.authedRequest(
                    path: "/family/v2/invite/\(inviteID.uuidString)"
                )
                let (data, http) = try await client.authedData(for: request)
                guard (200...299).contains(http.statusCode) else {
                    throw PairingV2ClientError(statusCode: http.statusCode)
                }
                return try JSONDecoder.pairingV2.decode(PairingInviteStatus.self, from: data)
            }
        )
    }
}
