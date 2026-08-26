import CryptoKit
import Foundation
import FamilyControls
import ManagedSettings

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
/// opaque blob (`POST /child/catalog-list` upsert). Named catalog entries are
/// also re-published for the new child-device row, while the blob makes the
/// whole selected set lockable immediately.
@MainActor
enum AppControlsBackendSync {

    private static var inFlight = false
    /// Last attempt timestamp — avoid hammering the endpoint on every poll
    /// tick when the backend is unreachable.
    private static var lastAttemptAt: Date?
    private static var lastAttemptDeviceID: UUID?
    private static let retryInterval: TimeInterval = 60
    private static var matchedCatalogInFlight = false
    private static var lastMatchedCatalogAttemptAt: Date?
    private static var lastMatchedCatalogAttemptDeviceID: UUID?

    /// Test seam: replaces the network call. Called with (deviceID, blob,
    /// appCount); returns the list id the backend assigned, or nil on failure.
    static var uploadOverride: ((UUID, String, Int) async -> UUID?)?
    static var matchedCatalogUploadOverride:
        ((UUID, [ChildAppCatalogUploadApp]) async throws -> ChildAppCatalogUploadResponse)?

    /// App-Group key holding the signature of the last successfully published
    /// selection, so roster edits (add/remove without bind) re-publish.
    private static let publishedSignatureKey = "evlin.lockGroup.publishedSignature"
    private static let publishedDeviceIDKey = "evlin.lockGroup.publishedDeviceID"

    /// A catalog-list alias belongs to one backend child-device row. It must
    /// never be replayed against a freshly paired row in another family.
    static func shouldPublish(
        deviceID: UUID,
        selectionSignature: String,
        lockedSetAliasKey: UUID?,
        publishedDeviceID: UUID?,
        publishedSignature: String?
    ) -> Bool {
        lockedSetAliasKey == nil
            || publishedDeviceID != deviceID
            || publishedSignature != selectionSignature
    }

    static func needsLockGroupUpload(
        force: Bool,
        deviceID: UUID,
        selectionSignature: String,
        lockedSetAliasKey: UUID?,
        publishedDeviceID: UUID?,
        publishedSignature: String?
    ) -> Bool {
        force || shouldPublish(
            deviceID: deviceID,
            selectionSignature: selectionSignature,
            lockedSetAliasKey: lockedSetAliasKey,
            publishedDeviceID: publishedDeviceID,
            publishedSignature: publishedSignature
        )
    }

    static func shouldThrottleLockGroupUpload(
        force: Bool,
        deviceID: UUID,
        lastAttemptDeviceID: UUID?,
        lastAttemptAt: Date?,
        now: Date = Date()
    ) -> Bool {
        guard !force,
              lastAttemptDeviceID == deviceID,
              let lastAttemptAt
        else { return false }
        return now.timeIntervalSince(lastAttemptAt) < retryInterval
    }

    static func aliasKeyForUpload(
        deviceID: UUID,
        lockedSetAliasKey: UUID?,
        publishedDeviceID: UUID?
    ) -> UUID? {
        publishedDeviceID == deviceID ? lockedSetAliasKey : nil
    }

    /// App Controls and Screen Time Tracking are separate Family Controls
    /// selections. This loader is intentionally read-only: publishing lock
    /// targets must never replace the wider selection used by total/device
    /// metering.
    static func retainedSelectionForCatalogUpload(
        load: () -> FamilyActivitySelection = { DefaultLockGroupStore.load() }
    ) -> FamilyActivitySelection {
        load()
    }

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
        guard mode == "child",
              let rawID = UserDefaults.standard.string(
                  forKey: CommandPoller.childDeviceIDDefaultsKey
              ),
              let deviceID = UUID(uuidString: rawID)
        else { return }

        Task { _ = await synchronizeRetainedAppControls(for: deviceID) }
    }

    /// Keep both backend projections of the retained App Controls selection
    /// converged. The lock-group blob and named matched-app catalog are
    /// separate channels; failure in either channel remains retryable on a
    /// later poll and neither channel may mutate Screen Time Tracking.
    @discardableResult
    static func synchronizeRetainedAppControls(
        for deviceID: UUID,
        publishLockGroup: (UUID) async -> Bool = { deviceID in
            await publishDefaultLockGroupIfNeeded(for: deviceID)
        },
        publishMatchedCatalog: (UUID) async -> Bool = { deviceID in
            await republishMatchedCatalogIfNeeded(for: deviceID)
        }
    ) async -> Bool {
        let listPublished = await publishLockGroup(deviceID)
        let catalogPublished = await publishMatchedCatalog(deviceID)
        return listPublished && catalogPublished
    }

    /// Rebind locally retained, named App Controls targets to a newly paired
    /// backend child-device row. Raw Screen Time tokens belong to this hardware
    /// and remain valid across pairing, but backend catalog IDs do not.
    @discardableResult
    static func republishMatchedCatalogIfNeeded(
        for deviceID: UUID,
        forceSnapshot: Bool = false
    ) async -> Bool {
        guard !matchedCatalogInFlight else { return false }
        if !forceSnapshot,
           lastMatchedCatalogAttemptDeviceID == deviceID,
           let lastAttempt = lastMatchedCatalogAttemptAt,
           Date().timeIntervalSince(lastAttempt) < retryInterval {
            return false
        }
        matchedCatalogInFlight = true
        lastMatchedCatalogAttemptAt = Date()
        lastMatchedCatalogAttemptDeviceID = deviceID
        defer { matchedCatalogInFlight = false }

        let selection = DefaultLockGroupStore.load()
        let store = LocalAliasStore.shared
        var appPairs: [(token: ApplicationToken, upload: ChildAppCatalogUploadApp)] = []
        var seenApps = Set<ApplicationToken>()

        for group in store.groupedApplicationAliases() {
            // Take the token the alias store holds, but only when the CURRENT
            // selection still contains it. The alias store deliberately never
            // deletes entries, so it can hand back a token captured under a
            // previous authorization grant — which uploads clean, arms clean,
            // reads back clean, and never fires (2026-08-06). The selection is
            // the only live evidence of what iOS will actually match.
            guard let token = group.keys.compactMap({
                store.applicationToken(forLookupKey: $0)
            }).first(where: { selection.applicationTokens.contains($0) }),
            seenApps.insert(token).inserted,
            (forceSnapshot || !store.hasCatalogConfirmation(
                forApplicationToken: token,
                childDeviceID: deviceID
            )),
            let tokenData = try? JSONEncoder().encode(token)
            else { continue }

            let displayName = group.label
                .split(separator: " ")
                .map { $0.prefix(1).uppercased() + $0.dropFirst() }
                .joined(separator: " ")
            appPairs.append((
                token,
                ChildAppCatalogUploadApp(
                    aliasKey: nil,
                    displayName: displayName,
                    bundleID: group.bundleID,
                    aliases: group.keys,
                    tokenAvailable: true,
                    tokenDataBase64: tokenData.base64EncodedString(),
                    sourceDeviceID: deviceID
                )
            ))
        }

        var categoryPairs: [(token: ActivityCategoryToken, upload: ChildAppCatalogUploadApp)] = []
        for token in selection.categoryTokens {
            let keys = store.categoryLookupKeys(equalTo: token)
            guard let first = keys.first,
                  (forceSnapshot || !store.hasCatalogConfirmation(
                      forCategoryToken: token,
                      childDeviceID: deviceID
                  )),
                  let tokenData = try? JSONEncoder().encode(token)
            else { continue }
            let displayName = first
                .split(separator: " ")
                .map { $0.prefix(1).uppercased() + $0.dropFirst() }
                .joined(separator: " ")
            categoryPairs.append((
                token,
                ChildAppCatalogUploadApp(
                    aliasKey: nil,
                    displayName: displayName,
                    tokenKind: "category",
                    aliases: keys,
                    tokenAvailable: true,
                    tokenDataBase64: tokenData.base64EncodedString(),
                    sourceDeviceID: deviceID
                )
            ))
        }

        let appUploads = appPairs.map { pair in pair.upload }
        let categoryUploads = categoryPairs.map { pair in pair.upload }
        let uploads = appUploads + categoryUploads
        guard forceSnapshot || !uploads.isEmpty else { return true }

        do {
            let response: ChildAppCatalogUploadResponse
            if let override = matchedCatalogUploadOverride {
                response = try await override(deviceID, uploads)
            } else {
                if forceSnapshot {
                    response = try await APIClient().uploadChildAppCatalog(
                        deviceID: deviceID,
                        apps: uploads
                    )
                } else {
                    response = try await APIClient().mergeChildAppCatalog(
                        deviceID: deviceID,
                        apps: uploads
                    )
                }
            }

            var confirmed = 0
            for pair in appPairs {
                guard let row = response.apps.first(where: {
                    $0.tokenKind.lowercased() != "category"
                        && $0.displayName.caseInsensitiveCompare(pair.upload.displayName) == .orderedSame
                        && $0.bundleID == pair.upload.bundleID
                }) else { continue }
                store.saveApplicationAliases(
                    token: pair.token,
                    displayName: pair.upload.displayName,
                    bundleIdentifier: pair.upload.bundleID,
                    catalogAliasKey: row.id,
                    catalogChildDeviceID: deviceID
                )
                confirmed += 1
            }
            for pair in categoryPairs {
                guard let row = response.apps.first(where: {
                    $0.tokenKind.lowercased() == "category"
                        && $0.displayName.caseInsensitiveCompare(pair.upload.displayName) == .orderedSame
                }) else { continue }
                store.saveCategoryToken(
                    pair.token,
                    forName: pair.upload.displayName,
                    catalogAliasKey: row.id,
                    catalogChildDeviceID: deviceID
                )
                for alias in pair.upload.aliases {
                    store.saveCategoryToken(
                        pair.token,
                        forName: alias,
                        catalogAliasKey: row.id,
                        catalogChildDeviceID: deviceID
                    )
                }
                confirmed += 1
            }
            return confirmed == uploads.count
        } catch {
            MeteringFlightRecorder.emitError(
                site: "pairing.matched_catalog_republish",
                error: error
            )
            return false
        }
    }

    /// The awaitable form is used by pairing so a new device identity starts
    /// publishing its retained local selection immediately. The backend
    /// reconciles any already-exhausted receipt after this upload, so a policy
    /// poll that races ahead still converges to the same shield.
    @discardableResult
    static func publishDefaultLockGroupIfNeeded(
        for explicitDeviceID: UUID? = nil,
        force: Bool = false
    ) async -> Bool {
        let mode = UserDefaults.standard.string(forKey: "appMode") ?? ""
        guard mode == "child" else { return false }
        let deviceID: UUID
        if let explicitDeviceID {
            deviceID = explicitDeviceID
        } else if let rawID = UserDefaults.standard.string(
            forKey: CommandPoller.childDeviceIDDefaultsKey
        ), let storedDeviceID = UUID(uuidString: rawID) {
            deviceID = storedDeviceID
        } else {
            return false
        }

        let selection = retainedSelectionForCatalogUpload()
        let appCount = selection.applicationTokens.count
        guard appCount > 0
            || !selection.categoryTokens.isEmpty
            || !selection.webDomainTokens.isEmpty
        else { return false }

        // Publish when the backend has no list under this identity yet, OR
        // when the local roster changed since the last publish (adding an app
        // WITHOUT binding it is local-only by design — the blob is the only
        // channel that keeps the backend's Locked set lockably complete).
        let sig = signature(of: selection)
        let suite = UserDefaults(suiteName: "group.com.evlin.ios")
        let publishedSig = suite?.string(forKey: publishedSignatureKey)
        let publishedDeviceID = suite?
            .string(forKey: publishedDeviceIDKey)
            .flatMap(UUID.init(uuidString:))
        let lockedSetAliasKey = EarnedTimeStore.shared.lockedSetListAliasKey
        guard needsLockGroupUpload(
            force: force,
            deviceID: deviceID,
            selectionSignature: sig,
            lockedSetAliasKey: lockedSetAliasKey,
            publishedDeviceID: publishedDeviceID,
            publishedSignature: publishedSig
        ) else { return true }

        guard !inFlight else { return false }
        if shouldThrottleLockGroupUpload(
            force: force,
            deviceID: deviceID,
            lastAttemptDeviceID: lastAttemptDeviceID,
            lastAttemptAt: lastAttemptAt
        ) {
            return false
        }
        inFlight = true
        lastAttemptAt = Date()
        lastAttemptDeviceID = deviceID

        guard let blob = try? AppCatalogBlobEncoder.base64(selection) else {
            inFlight = false
            return false
        }

        defer { inFlight = false }
        let listID: UUID?
        if let override = uploadOverride {
            listID = await override(deviceID, blob, appCount)
        } else {
            listID = try? await APIClient().uploadCatalogList(
                deviceID: deviceID,
                aliasKey: aliasKeyForUpload(
                    deviceID: deviceID,
                    lockedSetAliasKey: lockedSetAliasKey,
                    publishedDeviceID: publishedDeviceID
                ),
                listName: "Locked set",
                aliases: [],
                selectionBlobBase64: blob,
                appCount: appCount,
                allSelected: EarnedTimeStore.shared.lockedSetAllSelected
            ).aliasKey
        }
        guard let listID else { return false }
        EarnedTimeStore.shared.saveLockedSetListAliasKey(listID)
        EarnedTimeStore.shared.saveLockedSetID(listID.uuidString, tokenData: nil)
        UserDefaults(suiteName: "group.com.evlin.ios")?
            .set(sig, forKey: publishedSignatureKey)
        UserDefaults(suiteName: "group.com.evlin.ios")?
            .set(deviceID.uuidString.lowercased(), forKey: publishedDeviceIDKey)
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
        return true
    }
}

/// Guards the App Controls token stores against surviving an identity change.
///
/// Pairing deliberately used to preserve this hardware's selection, on the
/// premise that "raw Screen Time tokens belong to this hardware and remain
/// valid across pairing". Half of that is false: tokens are also scoped to the
/// authorization grant, so after an account is deleted and the device re-paired
/// they are inert. They still look real — the picker rows render, the catalog
/// uploads them, per-app monitors arm and read back clean — and then no
/// threshold ever fires, because iOS is watching an app that no longer exists
/// for this authorization. Real hardware, 2026-08-06: a fresh child device
/// re-uploaded the previous family's WhatsApp token within the same second it
/// was created, and every per-app limit built on it was silently dead.
enum AppControlsIdentityGuard {
    private static let ownerKey = "evlin.appControls.ownerChildDeviceID"
    private static let revokedKey = "evlin.appControls.sawAuthorizationRevoked"
    /// "approved" once a stable approved status has been observed, in ANY
    /// process, ever. The cross-process half of the revoke detector: the old
    /// process-local flag missed every revoke that happened while the app was
    /// not running (Enerel's iPad, 2026-08-11 — twelve rotated-dead tokens,
    /// endless `not_authorized` acks, and no re-pick prompt, because no
    /// process ever witnessed the approved→revoked edge).
    private static let lastStableKey = "evlin.appControls.lastStableAuthorization"

    private static var defaults: UserDefaults? {
        UserDefaults(suiteName: "group.com.evlin.ios")
    }

    /// Call at every point the kid device adopts a backend child-device
    /// identity. Purges the retained selection unless it was demonstrably
    /// captured under this same identity. An ABSENT stamp also purges: a
    /// selection saved before this guard existed carries no proof of which
    /// life it came from, and an unprovable token is exactly the failure this
    /// guard exists to stop.
    @MainActor
    static func adopt(childDeviceID: UUID) {
        let stamped = defaults?.string(forKey: ownerKey)
        defer { defaults?.set(childDeviceID.uuidString, forKey: ownerKey) }
        guard stamped != childDeviceID.uuidString else { return }
        ParentUnlockOverrideExpiry.clearForIdentityTeardown()
        purge(reason: stamped == nil ? "unstamped_selection" : "identity_changed")
    }

    /// Screen Time authorization going away and coming back ROTATES every
    /// token this device holds. iOS revokes silently (reinstalls are a known
    /// trigger, 2026-08-06), so the re-grant is the precise moment the retained
    /// selection becomes inert — cheaper and more accurate than purging on
    /// every onboarding run, which would punish device-restore flows that never
    /// lost their grant.
    /// True once this PROCESS has observed an approved status. The
    /// authorization publisher emits a provisional value at launch before the
    /// system finishes syncing, so a launch-time `.notDetermined` followed by
    /// the real `.approved` is NOT a revoke/re-grant round trip. Treating it as
    /// one wiped the freshly captured selection on every single launch
    /// (2026-08-07 02:47:31, observed on device) — far worse than the stale
    /// token this guard exists to prevent. Only a transition away from an
    /// approved status we already saw counts.
    @MainActor private static var sawApprovedThisProcess = false

    @MainActor
    static func noteAuthorizationApproved() {
        defer {
            sawApprovedThisProcess = true
            defaults?.set("approved", forKey: lastStableKey)
        }
        guard defaults?.bool(forKey: revokedKey) == true else { return }
        defaults?.set(false, forKey: revokedKey)
        purge(reason: "authorization_regranted")
    }

    /// `denied` distinguishes the two non-approved worlds. `.denied` is a
    /// STABLE fact — the user (or iOS) switched the grant off — and is what a
    /// relaunch observes after an out-of-process revoke. `.notDetermined` is
    /// ambiguous: the launch-time publisher emits it transiently before the
    /// real value arrives, and treating that as a revoke wiped the selection
    /// on every single launch (2026-08-07 02:47:31). So:
    ///   - in-process edge (we saw approved earlier this process) → revoke,
    ///     whatever the non-approved status is;
    ///   - cross-process: only an explicit `.denied` counts, and only when a
    ///     previous process persisted a stable approved.
    @MainActor
    static func noteAuthorizationRevoked(denied: Bool = false) {
        if sawApprovedThisProcess {
            defaults?.set(true, forKey: revokedKey)
            return
        }
        guard denied,
              defaults?.string(forKey: lastStableKey) == "approved"
        else { return }
        defaults?.set(true, forKey: revokedKey)
    }

    @MainActor
    static func purge(reason: String) {
        ScreenTimeManager.shared.clearSelectionForIdentityTeardown()
        DefaultLockGroupStore.clearAllListsForIdentityTeardown()
        LocalAliasStore.shared.removeAllAliases()
        defaults?.synchronize()
        MeteringFlightRecorder.emit(
            kind: .decision,
            site: "appControls.identityGuard",
            verdict: "purged",
            detail: MeteringFlightRecorder.detail([("reason", reason)])
        )
    }
}
