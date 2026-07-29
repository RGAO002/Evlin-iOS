import Foundation

/// How far a pairing-v2 identity adoption has progressed.
nonisolated enum PendingAdoptionPhase: String, Codable, Equatable, Sendable {
    /// Commit request is in flight or awaiting retry; `result` is still nil.
    case committing
    /// Restore path: converging the machinery this identity already owns.
    case converging
    /// Switch path: the cleanup intent is persisted with the engine.
    case cleanupPrepared
    /// New identity written locally; bootstrap has not finished.
    case identityWritten
}

/// The durable record that survives a relaunch mid-adoption.
///
/// Two things depend on this being written BEFORE the commit request goes out:
///
/// 1. A lost response is only recoverable if the device can rebuild a
///    byte-identical request. The server compares the choice/profile digest and
///    the device fingerprint, so `profile` and `deviceSnapshot` have to be here
///    — a record without them replays into a 409 and strands the device with
///    neither an identity nor a usable invite.
/// 2. The cleanup engine persists owner UUIDs and old routes, but nothing about
///    which family/profile the device is joining. Without that context a crash
///    between teardown and bootstrap leaves the device with the old identity
///    dismantled and no idea what to adopt.
nonisolated struct PendingAdoptionRecord: Codable, Equatable, Sendable {
    let operationID: UUID
    let inviteID: UUID?
    let commitRequestID: UUID
    let resolveSession: String
    let choice: AdoptionChoice
    /// Filled in once the commit response arrives.
    var result: PairingCommitResult?
    let oldUUID: UUID?
    var phase: PendingAdoptionPhase
    /// Canonical commit body inputs — see the note above.
    var profile: PairingNewChildProfile?
    var deviceSnapshot: [String: String]

    init(
        operationID: UUID = UUID(),
        inviteID: UUID?,
        commitRequestID: UUID = UUID(),
        resolveSession: String,
        choice: AdoptionChoice,
        result: PairingCommitResult? = nil,
        oldUUID: UUID?,
        phase: PendingAdoptionPhase = .committing,
        profile: PairingNewChildProfile? = nil,
        deviceSnapshot: [String: String] = [:]
    ) {
        self.operationID = operationID
        self.inviteID = inviteID
        self.commitRequestID = commitRequestID
        self.resolveSession = resolveSession
        self.choice = choice
        self.result = result
        self.oldUUID = oldUUID
        self.phase = phase
        self.profile = profile
        self.deviceSnapshot = deviceSnapshot
    }
}

/// Single-file JSON store, atomic writes. Cleared once bootstrap completes; a
/// record found at launch means an adoption was interrupted and must resume.
nonisolated final class PendingAdoptionStore: @unchecked Sendable {

    private let fileURL: URL

    init(directoryURL: URL) {
        self.fileURL = directoryURL.appendingPathComponent("pending-adoption.json")
    }

    /// App Group container, so the record outlives the app process and is
    /// visible to whichever component resumes the adoption.
    static func shared() -> PendingAdoptionStore? {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: ScreenTimeEventLog.suiteName
        ) else { return nil }
        return PendingAdoptionStore(directoryURL: container)
    }

    func save(_ record: PendingAdoptionRecord) throws {
        let data = try JSONEncoder().encode(record)
        try data.write(to: fileURL, options: .atomic)
    }

    func load() -> PendingAdoptionRecord? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(PendingAdoptionRecord.self, from: data)
    }

    func clear() {
        try? FileManager.default.removeItem(at: fileURL)
    }
}
