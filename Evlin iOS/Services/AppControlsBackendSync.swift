import CryptoKit
import Foundation
import FamilyControls

/// Re-publishes the kid's App-Controls selection to the backend when the
/// backend doesn't know about it.
///
/// The App-Controls roster (`DefaultLockGroupStore` + LocalAliasStore names)
/// lives in the App-Group and survives account switches and re-installs, but
/// backend catalog entries are family-scoped — after re-pairing under a new
/// family the parent sees a lockable-looking list while the backend's
/// "Locked set" is empty and the lock endpoint 422s
/// ("selected_set_missing_or_empty").
///
/// Detection: the identity-switch teardown clears
/// `EarnedTimeStore.lockedSetListAliasKey`. When that key is missing but the
/// local default lock group has tokens, the backend list hasn't been
/// published under the current identity yet — push the selection as an
/// opaque blob (`POST /child/catalog-list` upsert). Individual catalog
/// entries re-appear as the kid re-binds apps; the blob alone makes the set
/// lockable immediately (the lock command carries the blob AND the device
/// unions its local selection via the default_lock_group flag).
@MainActor
enum AppControlsBackendSync {

    private static var inFlight = false
    /// Last attempt timestamp — avoid hammering the endpoint on every poll
    /// tick when the backend is unreachable.
    private static var lastAttemptAt: Date?
    private static let retryInterval: TimeInterval = 60

    /// Test seam: replaces the network call. Called with (deviceID, blob,
    /// appCount); returns the list id the backend assigned, or nil on failure.
    static var uploadOverride: ((UUID, String, Int) async -> UUID?)?

    /// App-Group key holding the signature of the last successfully published
    /// selection, so roster edits (add/remove without bind) re-publish.
    private static let publishedSignatureKey = "evlin.lockGroup.publishedSignature"

    /// Order-independent, launch-stable fingerprint of the selection.
    /// (Swift's Hashable is seed-randomized per process, so hash the encoded
    /// token bytes instead and XOR-fold the digests.)
    static func signature(of selection: FamilyActivitySelection) -> String {
        var combined = [UInt8](repeating: 0, count: 32)
        let encoder = JSONEncoder()
        func fold<T: Encodable>(_ items: [T]) {
            for item in items {
                guard let data = try? encoder.encode(item) else { continue }
                for (i, byte) in SHA256.hash(data: data).enumerated() {
                    combined[i] ^= byte
                }
            }
        }
        fold(Array(selection.applicationTokens))
        fold(Array(selection.categoryTokens))
        fold(Array(selection.webDomainTokens))
        let counts = "\(selection.applicationTokens.count).\(selection.categoryTokens.count).\(selection.webDomainTokens.count)"
        return counts + ":" + combined.map { String(format: "%02x", $0) }.joined()
    }

    /// Push the default lock group to the backend if the current identity has
    /// no published list yet. Cheap no-op in the common case (one App-Group
    /// read). Safe to call from any poll tick or foreground pass.
    static func pushDefaultLockGroupIfNeeded() {
        let mode = UserDefaults.standard.string(forKey: "appMode") ?? ""
        guard mode == "child" else { return }
        guard let rawID = UserDefaults.standard.string(
                forKey: CommandPoller.childDeviceIDDefaultsKey),
              let deviceID = UUID(uuidString: rawID)
        else { return }

        let selection = DefaultLockGroupStore.load()
        let appCount = selection.applicationTokens.count
        guard appCount > 0
            || !selection.categoryTokens.isEmpty
            || !selection.webDomainTokens.isEmpty
        else { return }

        // Publish when the backend has no list under this identity yet, OR
        // when the local roster changed since the last publish (adding an app
        // WITHOUT binding it is local-only by design — the blob is the only
        // channel that keeps the backend's Locked set lockably complete).
        let sig = signature(of: selection)
        let suite = UserDefaults(suiteName: "group.com.evlin.ios")
        let publishedSig = suite?.string(forKey: publishedSignatureKey)
        guard EarnedTimeStore.shared.lockedSetListAliasKey == nil || publishedSig != sig
        else { return }

        guard !inFlight else { return }
        if let last = lastAttemptAt, Date().timeIntervalSince(last) < retryInterval { return }
        inFlight = true
        lastAttemptAt = Date()

        guard let blob = try? AppCatalogBlobEncoder.base64(selection) else {
            inFlight = false
            return
        }

        Task {
            defer { inFlight = false }
            let listID: UUID?
            if let override = uploadOverride {
                listID = await override(deviceID, blob, appCount)
            } else {
                listID = try? await APIClient().uploadCatalogList(
                    deviceID: deviceID,
                    aliasKey: EarnedTimeStore.shared.lockedSetListAliasKey,
                    listName: "Locked set",
                    aliases: [],
                    selectionBlobBase64: blob,
                    appCount: appCount,
                    allSelected: EarnedTimeStore.shared.lockedSetAllSelected
                ).aliasKey
            }
            guard let listID else { return }
            EarnedTimeStore.shared.saveLockedSetListAliasKey(listID)
            EarnedTimeStore.shared.saveLockedSetID(listID.uuidString, tokenData: nil)
            UserDefaults(suiteName: "group.com.evlin.ios")?
                .set(sig, forKey: publishedSignatureKey)
            ScreenTimeEventLog.emit(ScreenTimeEvent(
                ts: ISO8601DateFormatter().string(from: Date()),
                emitter: .kidApp,
                deviceID: deviceID.uuidString,
                dayKey: nil,
                kind: .decision,
                source: .earnedPool,
                app: "device-wide",
                reason: "lock_group_republished",
                nums: nil, transition: nil, policyGen: nil, corrID: nil))
        }
    }
}
