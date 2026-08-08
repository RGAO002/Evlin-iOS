import Foundation

/// One-time foreground migration for PINs created before server sync existed.
/// Work is budgeted and resumable so it cannot block the app's main thread.
@MainActor
final class ParentPINBackfill {
    static let shared = ParentPINBackfill(
        defaults: UserDefaults(suiteName: "group.com.evlin.ios"),
        pinStore: .shared,
        lifecycleStore: .shared
    )

    nonisolated static let budgetPerForeground = 250_000

    private let defaults: UserDefaults?
    private let pinStore: EvlinPINStore
    private let lifecycleStore: ParentPINLifecycleStore
    private let cursorKey = "evlin.parentPIN.recoveryCursor.v2"

    init(
        defaults: UserDefaults?,
        pinStore: EvlinPINStore,
        lifecycleStore: ParentPINLifecycleStore
    ) {
        self.defaults = defaults
        self.pinStore = pinStore
        self.lifecycleStore = lifecycleStore
    }

    func runIfNeeded(
        deviceID: UUID,
        baseURL: String,
        budget: Int = ParentPINBackfill.budgetPerForeground,
        remoteStatus: ParentPINRemoteStatus?
    ) async {
        guard lifecycleStore.pendingUpload() == nil,
              pinStore.isSet(),
              let material = pinStore.recoveryMaterial() else {
            return
        }
        // nil is a transport failure, not evidence that the server is empty.
        guard remoteStatus?.status == "not_set" else { return }
        let cursor = currentCursor()
        let outcome = await Task.detached(priority: .utility) {
            ParentPINRecovery.sweep(
                salt: material.salt,
                digest: material.digest,
                from: cursor,
                budget: budget,
                maxLength: ParentPINRecovery.autoMaxLength
            )
        }.value
        switch outcome {
        case .found(let pin):
            lifecycleStore.captureUpload(
                pin: pin,
                status: "available",
                deviceID: deviceID,
                baseURL: baseURL
            )
            resetCursor()
        case .budgetSpent(let next):
            saveCursor(next)
        case .exhausted:
            lifecycleStore.captureUpload(
                pin: nil,
                status: "unrecoverable",
                deviceID: deviceID,
                baseURL: baseURL
            )
            resetCursor()
        }
    }

    func currentCursor() -> ParentPINRecovery.Cursor {
        guard let data = defaults?.data(forKey: cursorKey),
              let cursor = try? JSONDecoder().decode(
                ParentPINRecovery.Cursor.self,
                from: data
              ) else {
            return ParentPINRecovery.startCursor
        }
        return cursor
    }

    @discardableResult
    func applyRemoteReset(
        _ remoteStatus: ParentPINRemoteStatus,
        deviceID: UUID
    ) -> Bool {
        guard lifecycleStore.acceptRemoteResetGeneration(
            remoteStatus.resetGeneration,
            deviceID: deviceID
        ) else { return false }
        pinStore.clear()
        resetCursor()
        return true
    }

    private func saveCursor(_ cursor: ParentPINRecovery.Cursor) {
        guard let data = try? JSONEncoder().encode(cursor) else { return }
        defaults?.set(data, forKey: cursorKey)
    }

    private func resetCursor() {
        defaults?.removeObject(forKey: cursorKey)
    }
}
