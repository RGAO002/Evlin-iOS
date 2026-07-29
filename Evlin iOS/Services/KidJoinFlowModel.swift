import Combine
import Foundation

/// Which screen the kid-side join flow should be showing.
nonisolated enum KidJoinStage: Equatable, Sendable {
    case scanning
    case resolving
    /// This hardware already has an identity in the inviting family.
    case offerRestore(childName: String, canSetUpSomeoneNew: Bool)
    /// Joining an existing child as an additional device.
    case confirmAddDevice(childName: String)
    /// Only a genuinely new child asks for a name and birth year.
    case collectNewChildProfile
    case committing
    case joined(PairingCommitResult)
    case failed(message: String)
}

/// Drives scan → resolve → branch → commit for the kid device.
///
/// Deliberately free of any coordinator dependency: the views own nothing but
/// rendering, and the host app wires the finished flow in at a single point.
@MainActor
final class KidJoinFlowModel: ObservableObject {

    @Published private(set) var stage: KidJoinStage = .scanning

    private let client: PairingV2Client
    private let store: PendingAdoptionStore
    private let deviceSnapshot: [String: String]
    private let currentOwnerUUID: UUID?

    private var resolved: PairingResolveResponse?

    init(
        client: PairingV2Client,
        store: PendingAdoptionStore,
        deviceSnapshot: [String: String],
        currentOwnerUUID: UUID?
    ) {
        self.client = client
        self.store = store
        self.deviceSnapshot = deviceSnapshot
        self.currentOwnerUUID = currentOwnerUUID
    }

    /// Where to go once the server has told us what this invite offers.
    ///
    /// Restore takes precedence: if this device already belongs to a child in
    /// this family, asking for a name would silently mint a duplicate identity.
    nonisolated static func stage(
        for response: PairingResolveResponse
    ) -> KidJoinStage {
        if let restore = response.restore {
            return .offerRestore(
                childName: restore.childDisplayName,
                canSetUpSomeoneNew: response.invited.purpose == .newChild
            )
        }
        switch response.invited.purpose {
        case .addDevice:
            return .confirmAddDevice(
                childName: response.invited.childDisplayName ?? "your child"
            )
        case .newChild:
            return .collectNewChildProfile
        }
    }

    func present(_ invite: ScannedInvite) async {
        stage = .resolving
        do {
            let response = try await client.resolve(invite, device: deviceSnapshot)
            resolved = response
            stage = Self.stage(for: response)
        } catch {
            stage = .failed(message: "That code didn't work. Ask your parent for a new one.")
        }
    }

    func choose(_ choice: AdoptionChoice,
                profile: PairingNewChildProfile? = nil) async {
        guard let response = resolved else { return }
        stage = .committing
        let record = PairingV2Client.makeCommitRecord(
            inviteID: nil,
            resolveSession: response.resolveSession,
            choice: choice,
            profile: profile,
            device: deviceSnapshot,
            oldUUID: currentOwnerUUID
        )
        do {
            let result = try await client.commit(record: record, store: store)
            stage = .joined(result)
        } catch {
            // The record is already on disk, so the adoption can still be
            // finished at next launch — this is a UI-level failure only.
            stage = .failed(message: "Couldn't finish setting up. Reopen Evlin to retry.")
        }
    }

    /// An add-device invite is intentionally bound to one existing child. It
    /// cannot silently become a new-child invite just because this hardware
    /// had a prior identity. Only a new-child invite may collect a new profile.
    func setUpSomeoneNew() {
        guard resolved?.invited.purpose == .newChild else { return }
        stage = .collectNewChildProfile
    }
}
