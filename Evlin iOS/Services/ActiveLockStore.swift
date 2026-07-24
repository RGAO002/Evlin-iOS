import Foundation
import FamilyControls
import ManagedSettings

nonisolated protocol ActiveLockShieldPersistence {
    func load() throws -> [String: ShieldRecord]
    func persist(_ shields: [String: ShieldRecord]) throws
}

private enum ActiveLockVerifiedPersistenceError: Error {
    case unavailable
    case readbackMismatch
}

nonisolated struct UserDefaultsActiveLockShieldPersistence: ActiveLockShieldPersistence {
    private let defaults: UserDefaults?
    private let storageKey: String

    init(defaults: UserDefaults?, storageKey: String = "evlin.shieldRecords") {
        self.defaults = defaults
        self.storageKey = storageKey
    }

    func load() throws -> [String: ShieldRecord] {
        guard let defaults else { throw ActiveLockVerifiedPersistenceError.unavailable }
        _ = defaults.synchronize()
        guard let data = defaults.data(forKey: storageKey) else { return [:] }
        let decoded: [String: ShieldRecord]
        if let json = try? Self.decoder.decode([String: ShieldRecord].self, from: data) {
            decoded = json
        } else if let legacy = try? PropertyListDecoder().decode(
            [String: ShieldRecord].self,
            from: data
        ) {
            decoded = legacy
        } else {
            throw ActiveLockVerifiedPersistenceError.readbackMismatch
        }
        let normalized = decoded.mapValues { $0.normalizedForCurrentSchema().record }
        guard normalized.allSatisfy({ $0.key == $0.value.recordKey }) else {
            throw ActiveLockVerifiedPersistenceError.readbackMismatch
        }
        return normalized
    }

    func persist(_ shields: [String: ShieldRecord]) throws {
        guard let defaults else { throw ActiveLockVerifiedPersistenceError.unavailable }
        let data = try Self.encoder.encode(shields)
        defaults.set(data, forKey: storageKey)
        _ = defaults.synchronize()
        guard defaults.data(forKey: storageKey) == data else {
            throw ActiveLockVerifiedPersistenceError.readbackMismatch
        }
        _ = try load()
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

/// Pure full-union projection of the active shield records onto the
/// ManagedSettings shield fields (C-3/R-2). Consumed by
/// `ActiveLockStore.recomputeAndApply()` — the ONLY main-app writer.
///
/// Precedence:
/// - applications: any `appliesToAll` record -> `.all`; otherwise the union of
///   app/category tokens (`.open` when both unions are empty).
/// - web: any broad record with `webOpen` -> `.open` (reflection playback);
///   else any broad tier `.all` record -> `.all` (parent full lock);
///   otherwise the union of web-domain tokens (`.open` when empty).
struct ActiveShieldProjection: Equatable {
    enum ApplicationsMode: Equatable {
        case all
        case specific(apps: Set<ApplicationToken>, categories: Set<ActivityCategoryToken>)
        case open
    }

    enum WebMode: Equatable {
        case all
        case specific(Set<WebDomainToken>)
        case open
    }

    let applications: ApplicationsMode
    let webDomains: WebMode

    static func make(records: [ShieldRecord]) -> ActiveShieldProjection {
        let broad = records.filter(\.appliesToAll)

        let applications: ApplicationsMode
        if !broad.isEmpty {
            applications = .all
        } else {
            let apps = Set(records.flatMap(\.appTokens))
            let categories = Set(records.flatMap(\.categoryTokens))
            applications = (apps.isEmpty && categories.isEmpty)
                ? .open
                : .specific(apps: apps, categories: categories)
        }

        let webDomains: WebMode
        switch ShieldWebProjectionDecision.resolve(records: records) {
        case .open:
            webDomains = .open
        case .all:
            webDomains = .all
        case .specific:
            let webs = Set(records.flatMap(\.webDomainTokens))
            webDomains = .specific(webs)
        }

        return ActiveShieldProjection(applications: applications, webDomains: webDomains)
    }
}

/// Single source of truth for active shields + blocks on this device.
/// See spec §3 for full design.
///
/// Data model:
/// - shieldRecords keyed by recordKey — same (tier, target) merges, different coexist.
/// - blockRecords keyed by bundleID — one block per app.
///
/// Mutations always run recomputeAndApply() to push the full union to ManagedSettingsStore.
actor ActiveLockStore {
    static let shared = ActiveLockStore()

    struct RekeyMutation: Sendable, Equatable {
        let original: ShieldRecord
        let migrated: ShieldRecord
    }

    struct ShieldMutationReceipt: Sendable, Equatable {
        let recordKey: String
        let before: ShieldRecord?
        let after: ShieldRecord
    }

    struct BlockMutationReceipt: Sendable, Equatable {
        let bundleID: String
        let before: BlockRecord?
        let after: BlockRecord
    }

    private var shieldRecords: [String: ShieldRecord] = [:]
    private var blockRecords: [String: BlockRecord] = [:]
    private let store = ManagedSettingsStore()
    private let defaults: UserDefaults?
    private let shieldPersistence: any ActiveLockShieldPersistence
    private let shieldsKey = "evlin.shieldRecords"
    private let blocksKey = "evlin.blockRecords"

    init(
        defaults: UserDefaults? = UserDefaults(suiteName: "group.com.evlin.ios"),
        shieldPersistence: (any ActiveLockShieldPersistence)? = nil
    ) {
        self.defaults = defaults
        self.shieldPersistence = shieldPersistence ?? UserDefaultsActiveLockShieldPersistence(
            defaults: defaults
        )
        _ = ActiveLockPersistenceLock.shared.withLock {
            restore()
        }
    }

    // MARK: - Shield API

    /// Add a shield. If `force == true`, the merge rule is skipped — use this
    /// ONLY when the parent has confirmed a downgrade via the B1 card. The caller
    /// (ActionExecutor) reads the `force_downgrade` flag from the Command payload;
    /// the parent UI sends that flag by re-submitting the Chat message with
    /// `force_confirmations: ["B1"]` in the request.
    @discardableResult
    func addShield(_ new: ShieldRecord, force: Bool = false) -> AddShieldResult {
        ActiveLockPersistenceLock.shared.withLock {
            guard reloadDurableState() else { return .noOpShorterThanExisting }
            let new = normalizeShieldRecord(new).record
            if let existing = shieldRecords[new.recordKey], !force {
                return mergeShield(existing: existing, new: new)
            }
            // force=true OR no existing record → overwrite
            shieldRecords[new.recordKey] = new
            persist()
            recomputeAndApply()
            return .added
        } ?? .noOpShorterThanExisting
    }

    /// Persist a shield mutation and return the exact durable before/after values.
    /// Stale-command rollback must use this receipt instead of a separate read.
    func addShieldWithReceipt(
        _ new: ShieldRecord,
        force: Bool = false
    ) -> (result: AddShieldResult, receipt: ShieldMutationReceipt)? {
        ActiveLockPersistenceLock.shared.withLock {
            guard reloadDurableState() else { return nil }
            let normalized = normalizeShieldRecord(new).record
            let before = shieldRecords[normalized.recordKey]
            let result = addShield(normalized, force: force)
            guard persistAndVerify(), reloadDurableState(),
                  let after = shieldRecords[normalized.recordKey]
            else {
                _ = reloadDurableState()
                recomputeAndApply()
                return nil
            }
            return (
                result,
                ShieldMutationReceipt(
                    recordKey: normalized.recordKey,
                    before: before,
                    after: after
                )
            )
        } ?? nil
    }

    /// Compare-and-swap rollback against durable state. A newer command or
    /// extension write at the same key wins and is never overwritten.
    @discardableResult
    func rollbackShieldMutation(_ receipt: ShieldMutationReceipt) -> Bool {
        ActiveLockPersistenceLock.shared.withLock {
            guard reloadDurableState() else { return false }
            guard shieldRecords[receipt.recordKey] == receipt.after else {
                recomputeAndApply()
                return false
            }
            if let before = receipt.before {
                shieldRecords[receipt.recordKey] = before
            } else {
                shieldRecords.removeValue(forKey: receipt.recordKey)
            }
            guard persistAndVerify() else {
                _ = reloadDurableState()
                recomputeAndApply()
                return false
            }
            recomputeAndApply()
            return true
        } ?? false
    }

    @discardableResult
    func removeShield(recordKey: String) -> RemovedShield? {
        ActiveLockPersistenceLock.shared.withLock {
            guard reloadDurableState() else { return nil }
            guard let record = shieldRecords.removeValue(forKey: recordKey) else { return nil }
            persist()
            recomputeAndApply()
            let stillCovered = findRemainingCoverage(of: record)
            let blocked = false
            return RemovedShield(record: record, stillCovered: stillCovered, blockedAfter: blocked)
        } ?? nil
    }

    @discardableResult
    func unshieldAll() -> [ShieldRecord] {
        ActiveLockPersistenceLock.shared.withLock {
            guard reloadDurableState() else { return [] }
            let removed = Array(shieldRecords.values)
            shieldRecords.removeAll()
            persist()
            recomputeAndApply()
            return removed
        } ?? []
    }

    /// Resilience fallback for an unshield of a CATEGORY whose token the command
    /// could not carry/resolve (no `catalog_category_token_data`, and the
    /// `category_hint`/display doesn't resolve to a local category token, so the
    /// recordKey-keyed `removeShield(recordKey:)` finds nothing). Without this a
    /// parent's "unlock Social" silently no-ops and the receipt falls back to
    /// "App".
    ///
    /// Matches active `.category`-tier records whose `displayName` equals `hint`
    /// case-insensitively (e.g. stored "Social" vs command hint "social"),
    /// removes them, recomputes, and returns the removed records (the caller acks
    /// with the matched record's real `displayName`). Returns `[]` when nothing
    /// matches — the caller keeps its existing `.nothingToUnlock` path.
    @discardableResult
    func removeCategoryShieldsByDisplayName(_ hint: String) -> [ShieldRecord] {
        ActiveLockPersistenceLock.shared.withLock {
            guard reloadDurableState() else { return [] }
            let needle = hint.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !needle.isEmpty else { return [] }
            let toRemove = shieldRecords.values.filter {
                $0.tier == .category
                    && $0.displayName.caseInsensitiveCompare(needle) == .orderedSame
            }
            guard !toRemove.isEmpty else { return [] }
            for record in toRemove {
                shieldRecords.removeValue(forKey: record.recordKey)
            }
            persist()
            recomputeAndApply()
            return toRemove
        } ?? []
    }

    /// Surgically remove a single APP token from every live `.savedList`
    /// (Locked-set) shield's baked snapshot, then recompute + re-apply.
    ///
    /// The Locked-set shield bakes a token snapshot at lock time and does NOT
    /// refresh on its own. When the parent removes one app from the App Controls
    /// picker while the Locked set is shielded RIGHT NOW, this drops just that
    /// token from the live shield so the app unshields IMMEDIATELY — no
    /// unlock→relock dance. No-ops (no persist/recompute) when nothing matches.
    func dropTokenFromSavedListShields(app token: ApplicationToken) {
        _ = ActiveLockPersistenceLock.shared.withLock {
            guard reloadDurableState() else { return }
            applyDropFromSavedListShields { record in
                guard record.appTokens.contains(token) else { return nil }
                var updated = record
                updated.appTokens.remove(token)
                return updated
            }
        }
    }

    /// Sibling of `dropTokenFromSavedListShields(app:)` for a CATEGORY token —
    /// drops it from every live `.savedList` shield's baked snapshot so a category
    /// removed from the picker unshields immediately while the Locked set is held.
    func dropTokenFromSavedListShields(category token: ActivityCategoryToken) {
        _ = ActiveLockPersistenceLock.shared.withLock {
            guard reloadDurableState() else { return }
            applyDropFromSavedListShields { record in
                guard record.categoryTokens.contains(token) else { return nil }
                var updated = record
                updated.categoryTokens.remove(token)
                return updated
            }
        }
    }

    /// Apply `transform` to every `.savedList` shield. `transform` returns the
    /// updated record (token removed) or `nil` to leave it untouched. A
    /// `.savedList` record left with no tokens at all is deleted entirely.
    /// Persists + recomputes only when at least one record actually changed.
    private func applyDropFromSavedListShields(_ transform: (ShieldRecord) -> ShieldRecord?) {
        var changed = false
        for record in shieldRecords.values where record.tier == .savedList {
            guard let updated = transform(record) else { continue }
            if updated.appTokens.isEmpty, updated.categoryTokens.isEmpty,
               updated.webDomainTokens.isEmpty, !updated.appliesToAll {
                shieldRecords.removeValue(forKey: record.recordKey)
            } else {
                shieldRecords[record.recordKey] = updated
            }
            changed = true
        }
        guard changed else { return }
        persist()
        recomputeAndApply()
    }

    /// Remove every `source == .limit` shield that covers the given per-app limit
    /// rule's app, then recompute. Used by `clear_limit` (P6) so clearing a limit
    /// also unshields if the limit had auto-shielded the app. Matches a limit
    /// shield when it shares any of the rule's `appTokens` OR its `targetKey`
    /// equals the rule's lowercased `bundleID` (the exactApp recordKey scheme).
    ///
    /// `source == .manual` (parent/reflection) shields are NEVER touched, even if
    /// they cover the same app — only the limit subsystem's own shields are dropped.
    @discardableResult
    func removeLimitShields(appTokens: Set<ApplicationToken>, bundleID: String?) -> [ShieldRecord] {
        ActiveLockPersistenceLock.shared.withLock {
            guard reloadDurableState() else { return [] }
            let bidKey = bundleID?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let toRemove = shieldRecords.values.filter { record in
                guard record.sources.contains(.limit) else { return false }
                if !appTokens.isEmpty, !record.appTokens.isDisjoint(with: appTokens) { return true }
                if let bidKey, !bidKey.isEmpty, record.targetKey == bidKey { return true }
                return false
            }
            guard !toRemove.isEmpty else { return [] }
            for record in toRemove {
                shieldRecords.removeValue(forKey: record.recordKey)
            }
            persist()
            recomputeAndApply()
            return toRemove
        } ?? []
    }

    /// Removes only `.limit` ownership and commits the complete shield dictionary
    /// through synchronized byte readback before updating the actor snapshot.
    @discardableResult
    func removeLimitSourceVerified(
        appTokens: Set<ApplicationToken> = [],
        bundleID: String? = nil,
        ruleID: UUID? = nil
    ) throws -> [ShieldRecord] {
        var result: Result<[ShieldRecord], Error>?
        guard ActiveLockPersistenceLock.shared.withLock({
            result = Result {
                let durable = try shieldPersistence.load()
                let bidKey = bundleID?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased()
                let matching = durable.values.filter { record in
                    guard record.sources.contains(.limit) else { return false }
                    if let ruleID {
                        return record.limitRuleIDs.contains(ruleID)
                    }
                    if !appTokens.isEmpty,
                       !record.appTokens.isDisjoint(with: appTokens) {
                        return true
                    }
                    if let bidKey, !bidKey.isEmpty, record.targetKey == bidKey {
                        return true
                    }
                    return false
                }

                var updated = durable
                for record in matching {
                    if let ruleID, !record.limitRuleIDs.isEmpty {
                        var remaining = record
                        remaining.limitRuleIDs.remove(ruleID)
                        if remaining.limitRuleIDs.isEmpty {
                            updated = ShieldSourceLogic.removingSource(
                                .limit,
                                fromRecordKey: record.recordKey,
                                in: updated
                            )
                        } else {
                            updated[record.recordKey] = remaining
                        }
                    } else {
                        updated = ShieldSourceLogic.removingSource(
                            .limit,
                            fromRecordKey: record.recordKey,
                            in: updated
                        )
                    }
                }
                if !matching.isEmpty { try shieldPersistence.persist(updated) }
                let readback = try shieldPersistence.load()
                guard Set(readback.keys) == Set(updated.keys),
                      readback.allSatisfy({ $0.key == $0.value.recordKey }),
                      readback.allSatisfy({ key, record in
                          record.sources == updated[key]?.sources
                              && record.limitRuleIDs == updated[key]?.limitRuleIDs
                      })
                else {
                    throw ActiveLockVerifiedPersistenceError.readbackMismatch
                }
                if let ruleID {
                    let unresolved = readback.values.contains { record in
                        guard record.sources.contains(.limit) else { return false }
                        return record.limitRuleIDs.contains(ruleID)
                            || (matching.isEmpty && record.limitRuleIDs.isEmpty)
                    }
                    guard !unresolved else {
                        throw ActiveLockVerifiedPersistenceError.readbackMismatch
                    }
                }
                shieldRecords = readback
                recomputeAndApply()
                return matching
            }
        }) != nil else {
            throw ActiveLockVerifiedPersistenceError.unavailable
        }
        return try result!.get()
    }

    // MARK: - Block API

    @discardableResult
    func addBlock(_ new: BlockRecord) -> AddBlockResult {
        ActiveLockPersistenceLock.shared.withLock {
            guard reloadDurableState() else { return .alreadyBlocked }
            if blockRecords[new.bundleID] != nil { return .alreadyBlocked }
            blockRecords[new.bundleID] = new
            persist()
            recomputeAndApply()
            return .added
        } ?? .alreadyBlocked
    }

    func addBlockWithReceipt(
        _ new: BlockRecord
    ) -> (result: AddBlockResult, receipt: BlockMutationReceipt)? {
        ActiveLockPersistenceLock.shared.withLock {
            guard reloadDurableState() else { return nil }
            let before = blockRecords[new.bundleID]
            let result: AddBlockResult
            if before == nil {
                blockRecords[new.bundleID] = new
                result = .added
            } else {
                result = .alreadyBlocked
            }
            guard persistAndVerify(), reloadDurableState(),
                  let after = blockRecords[new.bundleID]
            else {
                _ = reloadDurableState()
                recomputeAndApply()
                return nil
            }
            recomputeAndApply()
            return (
                result,
                BlockMutationReceipt(bundleID: new.bundleID, before: before, after: after)
            )
        } ?? nil
    }

    @discardableResult
    func rollbackBlockMutation(_ receipt: BlockMutationReceipt) -> Bool {
        ActiveLockPersistenceLock.shared.withLock {
            guard reloadDurableState() else { return false }
            guard blockRecords[receipt.bundleID] == receipt.after else {
                recomputeAndApply()
                return false
            }
            if let before = receipt.before {
                blockRecords[receipt.bundleID] = before
            } else {
                blockRecords.removeValue(forKey: receipt.bundleID)
            }
            guard persistAndVerify() else {
                _ = reloadDurableState()
                recomputeAndApply()
                return false
            }
            recomputeAndApply()
            return true
        } ?? false
    }

    @discardableResult
    func removeBlock(bundleID: String, categoryHint: String? = nil) -> RemovedBlock? {
        ActiveLockPersistenceLock.shared.withLock {
            guard reloadDurableState() else { return nil }
            guard let record = blockRecords.removeValue(forKey: bundleID) else { return nil }
            persist()
            recomputeAndApply()
            // Pass categoryHint so shields on the matching category ARE detected.
            let query = AppQuery(bundleID: bundleID, categoryHint: categoryHint?.lowercased())
            let state = effectiveState(for: query)
            return RemovedBlock(
                record: record,
                stillShieldedBy: state.shieldsCovering,
                possibleSavedListCoverage: state.possibleSavedListCoverage
            )
        } ?? nil
    }

    @discardableResult
    func unblockAll() -> [BlockRecord] {
        ActiveLockPersistenceLock.shared.withLock {
            guard reloadDurableState() else { return [] }
            let removed = Array(blockRecords.values)
            blockRecords.removeAll()
            persist()
            recomputeAndApply()
            return removed
        } ?? []
    }

    // MARK: - Queries

    func allCurrent() -> (shields: [ShieldRecord], blocks: [BlockRecord]) {
        (Array(shieldRecords.values), Array(blockRecords.values))
    }

    func reapplyCurrentRestrictions() {
        _ = ActiveLockPersistenceLock.shared.withLock {
            guard reloadDurableState() else { return }
            recomputeAndApply()
        }
    }

    func effectiveState(for query: AppQuery) -> EffectiveState {
        var state = EffectiveState(
            isBlocked: false,
            shieldsCovering: [],
            possibleSavedListCoverage: false,
            earliestFullyUnrestricted: nil
        )

        if let bid = query.bundleID, blockRecords[bid] != nil {
            state.isBlocked = true
        }

        for record in shieldRecords.values {
            if shieldCovers(record, query: query) {
                state.shieldsCovering.append(record)
            } else if record.tier == .savedList, query.token == nil {
                state.possibleSavedListCoverage = true
            }
        }

        let hasPermanent = state.shieldsCovering.contains(where: { $0.expiresAt == nil })
        if state.isBlocked || hasPermanent || state.possibleSavedListCoverage {
            state.earliestFullyUnrestricted = nil
        } else {
            state.earliestFullyUnrestricted = state.shieldsCovering.compactMap(\.expiresAt).max()
        }
        return state
    }

    // MARK: - Time management

    @discardableResult
    func sweepExpired(now: Date = Date()) -> [ShieldRecord] {
        ActiveLockPersistenceLock.shared.withLock {
            guard reloadDurableState() else { return [] }
            let expired = purgeExpiredRecords(now: now)
            guard !expired.shields.isEmpty || !expired.blocks.isEmpty else { return [] }
            persist()
            recomputeAndApply()
            return expired.shields
        } ?? []
    }

    // MARK: - Private: merge

    private func mergeShield(existing: ShieldRecord, new: ShieldRecord) -> AddShieldResult {
        let existingPermanent = existing.expiresAt == nil
        let newPermanent = new.expiresAt == nil

        if existingPermanent && newPermanent {
            // Both permanent: no expiry change, but we MUST still union sources.
            // (e.g. earnedTime + manual are both permanent; earned-time and manual
            // both write permanent records to the same recordKey.)
            let merged = ShieldSourceLogic.unioning(
                existing,
                intoSources: new.sources,
                limitRuleIDs: new.limitRuleIDs
            )
            if merged != existing {
                shieldRecords[existing.recordKey] = merged
                persist()
                recomputeAndApply()
            }
            return .noOpAlreadyPermanent
        }
        if existingPermanent && !newPermanent {
            // Existing permanent, new is timed — union sources but keep permanent.
            let merged = ShieldSourceLogic.unioning(
                existing,
                intoSources: new.sources,
                limitRuleIDs: new.limitRuleIDs
            )
            if merged != existing {
                shieldRecords[existing.recordKey] = merged
                persist()
                recomputeAndApply()
            }
            return .needsConfirmation(.downgradePermanentToTimed(
                existingKey: existing.recordKey,
                newExpiry: new.expiresAt!
            ))
        }
        if !existingPermanent && newPermanent {
            var upgraded = ShieldSourceLogic.unioning(
                existing,
                intoSources: new.sources,
                limitRuleIDs: new.limitRuleIDs
            )
            let prev = upgraded.expiresAt!
            upgraded.expiresAt = nil
            upgraded.lastCommandID = new.lastCommandID
            upgraded.displayName = new.displayName
            shieldRecords[existing.recordKey] = upgraded
            persist()
            recomputeAndApply()
            return .upgradedToPermanent(previousExpiry: prev)
        }
        if new.expiresAt! > existing.expiresAt! {
            var extended = ShieldSourceLogic.unioning(
                existing,
                intoSources: new.sources,
                limitRuleIDs: new.limitRuleIDs
            )
            extended.expiresAt = new.expiresAt
            extended.lastCommandID = new.lastCommandID
            shieldRecords[existing.recordKey] = extended
            persist()
            recomputeAndApply()
            return .extendedTimed(newExpiry: new.expiresAt!)
        }
        // New expiry is shorter than existing: still union sources, no expiry change.
        let merged = ShieldSourceLogic.unioning(
            existing,
            intoSources: new.sources,
            limitRuleIDs: new.limitRuleIDs
        )
        if merged != existing {
            shieldRecords[existing.recordKey] = merged
            persist()
            recomputeAndApply()
        }
        return .noOpShorterThanExisting
    }

    // MARK: - B6: recordKey migration

    /// Re-key the `savedList:<localID>` shield record to `savedList:<backendID>`,
    /// preserving all fields (sources, expiry, tokens, timestamps). Idempotent:
    ///
    /// - If the record is already keyed by `backendID` → no-op.
    /// - If no record exists for `localID` → no-op.
    /// - If `localID == backendID` → no-op (identity).
    ///
    /// Called once the backend `ChildCatalogList.id` is first learned
    /// (via `EarnedTimeStore.saveLockedSetID`). Safe to call multiple times.
    @discardableResult
    func reKeyShieldRecord(
        fromLocalID localID: String,
        toBackendID backendID: String
    ) -> RekeyMutation? {
        ActiveLockPersistenceLock.shared.withLock {
            guard reloadDurableState(), localID != backendID else { return nil }

            let oldKey = ShieldRecord.makeRecordKey(tier: .savedList, targetKey: localID)
            let newKey = ShieldRecord.makeRecordKey(tier: .savedList, targetKey: backendID)

            // Idempotent: if the new key already exists, the migration already ran.
            if shieldRecords[newKey] != nil { return nil }

            // Find the old record.
            guard let old = shieldRecords[oldKey] else { return nil }

            // Build the migrated record — same content, new key + targetKey.
            let migrated = ShieldRecord(
                recordKey: newKey,
                tier: .savedList,
                targetKey: backendID,
                displayName: old.displayName,
                lastCommandID: old.lastCommandID,
                appTokens: old.appTokens,
                categoryTokens: old.categoryTokens,
                webDomainTokens: old.webDomainTokens,
                appliesToAll: old.appliesToAll,
                issuedAt: old.issuedAt,
                expiresAt: old.expiresAt,
                originalRequest: old.originalRequest,
                targetChildID: old.targetChildID,
                sources: old.sources,
                limitRuleIDs: old.limitRuleIDs,
                webOpen: old.webOpen
            )

            shieldRecords.removeValue(forKey: oldKey)
            shieldRecords[newKey] = migrated
            guard persistAndVerify(), reloadDurableState(),
                  let durableMigrated = shieldRecords[newKey]
            else {
                _ = reloadDurableState()
                recomputeAndApply()
                return nil
            }
            recomputeAndApply()
            return RekeyMutation(original: old, migrated: durableMigrated)
        } ?? nil
    }

    func rollbackRekey(_ mutation: RekeyMutation) {
        _ = ActiveLockPersistenceLock.shared.withLock {
            guard reloadDurableState(),
                  shieldRecords[mutation.migrated.recordKey] == mutation.migrated,
                  shieldRecords[mutation.original.recordKey] == nil
            else {
                recomputeAndApply()
                return false
            }
            shieldRecords.removeValue(forKey: mutation.migrated.recordKey)
            shieldRecords[mutation.original.recordKey] = mutation.original
            guard persistAndVerify() else {
                _ = reloadDurableState()
                recomputeAndApply()
                return false
            }
            recomputeAndApply()
            return true
        }
    }

    /// Remove a single source from the record at `recordKey`. If the record's
    /// `sources` set becomes empty the record is deleted entirely. No-ops
    /// silently if `recordKey` is not found.
    func removeSource(_ source: ShieldSource, fromRecordKey key: String) {
        _ = ActiveLockPersistenceLock.shared.withLock {
            guard reloadDurableState() else { return }
            shieldRecords = ShieldSourceLogic.removingSource(source, fromRecordKey: key, in: shieldRecords)
            persist()
            recomputeAndApply()
        }
    }

    // MARK: - Private: coverage query

    private func shieldCovers(_ record: ShieldRecord, query: AppQuery) -> Bool {
        switch record.tier {
        case .all, .allApps:
            return true
        case .exactApp:
            if let t = query.token, record.appTokens.contains(t) { return true }
            if let raw = query.bundleID {
                let bid = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                if !bid.isEmpty, record.targetKey == bid.lowercased() {
                    return true
                }
            }
            return false
        case .savedList:
            if let t = query.token, record.appTokens.contains(t) { return true }
            return false
        case .category:
            if let hint = query.categoryHint, record.targetKey == hint { return true }
            return false
        }
    }

    private func findRemainingCoverage(of removed: ShieldRecord) -> [ShieldRecord] {
        shieldRecords.values.filter { other in
            if other.recordKey == removed.recordKey { return false }
            switch removed.tier {
            case .exactApp:
                return !other.appTokens.isDisjoint(with: removed.appTokens) || other.appliesToAll
            case .savedList:
                return !other.appTokens.isDisjoint(with: removed.appTokens) ||
                       !other.categoryTokens.isDisjoint(with: removed.categoryTokens) ||
                       other.appliesToAll
            case .category:
                return (other.tier == .category && other.targetKey == removed.targetKey) ||
                       other.appliesToAll
            case .all, .allApps:
                return false
            }
        }
    }

    // MARK: - Private: recompute + persistence

    private func recomputeAndApply() {
        let expired = purgeExpiredRecords()
        if !expired.shields.isEmpty || !expired.blocks.isEmpty {
            persist()
        }

        // Blocks
        let blockedApps = Set(blockRecords.values.map { ManagedSettings.Application(bundleIdentifier: $0.bundleID) })
        store.application.blockedApplications = blockedApps.isEmpty ? nil : blockedApps

        // Shields: apply the pure full-union projection. This is the ONLY
        // main-app write of the ManagedSettings shield fields (C-3/R-2).
        let projection = ActiveShieldProjection.make(records: Array(shieldRecords.values))

        switch projection.applications {
        case .all:
            store.shield.applicationCategories = .all()
            store.shield.applications = nil
        case .specific(let apps, let categories):
            store.shield.applications = apps.isEmpty ? nil : apps
            store.shield.applicationCategories = categories.isEmpty ? nil : .specific(categories)
        case .open:
            store.shield.applications = nil
            store.shield.applicationCategories = nil
        }

        switch projection.webDomains {
        case .all:
            store.shield.webDomainCategories = .all()
            store.shield.webDomains = nil
        case .specific(let webs):
            store.shield.webDomainCategories = nil
            store.shield.webDomains = webs
        case .open:
            store.shield.webDomainCategories = nil
            store.shield.webDomains = nil
        }

        writeRecomputeDiag(projection: projection)
    }

    /// Records the most recent recomputeAndApply() invocation to the App Group
    /// so HomeSettingsSheet can surface it. This is the only way to verify
    /// that sweepExpired → recomputeAndApply actually executed AND what value
    /// it wrote to `store.shield.applications` (which we can't read back).
    /// Branch names ("all" / "all_apps_only" / "union") are stable diagnostics
    /// vocabulary predating the projection — derived from it, not renamed.
    private func writeRecomputeDiag(projection: ActiveShieldProjection) {
        let branch: String
        var appTokens = 0, catTokens = 0, webTokens = 0
        switch (projection.applications, projection.webDomains) {
        case (.all, .all):
            branch = "all"
        case (.all, _):
            branch = "all_apps_only"
        default:
            branch = "union"
        }
        if case .specific(let apps, let categories) = projection.applications {
            appTokens = apps.count
            catTokens = categories.count
        }
        if case .specific(let webs) = projection.webDomains {
            webTokens = webs.count
        }
        let ts = ISO8601DateFormatter().string(from: Date())
        let line = "\(ts) branch=\(branch) shields=\(shieldRecords.count) blocks=\(blockRecords.count)"
            + " apps=\(appTokens) cats=\(catTokens) webs=\(webTokens)"
        defaults?.set(line, forKey: "evlin.lastRecompute")
    }

    private func persist() {
        // `PropertyListEncoder` can trip `swift_dynamicCastFailure` encoding
        // `ShieldRecord`'s FamilyControls token sets (crash seen iOS 26 / TestFlight).
        // JSON survives the full Codable surface for `[String: ShieldRecord]`.
        // Explicit ISO8601 date strategy pins the on-wire format so future encoder
        // changes can't shift Date representation under us.
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(shieldRecords) {
            defaults?.set(data, forKey: shieldsKey)
        }
        if let data = try? encoder.encode(blockRecords) {
            defaults?.set(data, forKey: blocksKey)
        }
    }

    private func persistAndVerify() -> Bool {
        guard let defaults else { return false }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let shieldsData = try? encoder.encode(shieldRecords),
              let blocksData = try? encoder.encode(blockRecords)
        else { return false }
        defaults.set(shieldsData, forKey: shieldsKey)
        defaults.set(blocksData, forKey: blocksKey)
        guard defaults.synchronize() else { return false }
        return defaults.data(forKey: shieldsKey) == shieldsData
            && defaults.data(forKey: blocksKey) == blocksData
    }

    /// Replace the actor snapshot with the complete persisted dictionaries.
    /// Missing keys are legitimate empty stores; decode failures fail closed.
    private func reloadDurableState() -> Bool {
        guard let defaults else { return false }
        defaults.synchronize()
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let durableShields: [String: ShieldRecord]
        if let data = defaults.data(forKey: shieldsKey) {
            if let decoded = try? decoder.decode([String: ShieldRecord].self, from: data) {
                durableShields = decoded
            } else if let decoded = try? PropertyListDecoder().decode([String: ShieldRecord].self, from: data) {
                durableShields = decoded
            } else {
                return false
            }
        } else {
            durableShields = [:]
        }

        let durableBlocks: [String: BlockRecord]
        if let data = defaults.data(forKey: blocksKey) {
            if let decoded = try? decoder.decode([String: BlockRecord].self, from: data) {
                durableBlocks = decoded
            } else if let decoded = try? PropertyListDecoder().decode([String: BlockRecord].self, from: data) {
                durableBlocks = decoded
            } else {
                return false
            }
        } else {
            durableBlocks = [:]
        }

        shieldRecords = durableShields.mapValues { normalizeShieldRecord($0).record }
        blockRecords = durableBlocks
        return true
    }

    private func restore() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var migrated = false
        if let data = defaults?.data(forKey: shieldsKey) {
            if let decoded = try? decoder.decode([String: ShieldRecord].self, from: data) {
                shieldRecords = decoded.mapValues { record in
                    let normalized = normalizeShieldRecord(record)
                    migrated = migrated || normalized.migrated
                    return normalized.record
                }
            } else if let decoded = try? PropertyListDecoder().decode([String: ShieldRecord].self, from: data) {
                shieldRecords = decoded.mapValues { record in
                    let normalized = normalizeShieldRecord(record)
                    migrated = migrated || normalized.migrated
                    return normalized.record
                }
                // One-shot migrate legacy plist payloads to JSON after blocks restore below.
                migrated = true
            }
        }
        if let data = defaults?.data(forKey: blocksKey) {
            if let decoded = try? decoder.decode([String: BlockRecord].self, from: data) {
                blockRecords = decoded
            } else if let decoded = try? PropertyListDecoder().decode([String: BlockRecord].self, from: data) {
                blockRecords = decoded
                migrated = true
            }
        }

        // Wave-1 Task 5: one-time re-key sweep for the "immortal lock" bug.
        // Older persisted stores may hold `savedList:<UPPERCASE>` keys written
        // before `makeRecordKey` normalized to lowercase (e.g. via the
        // pre-B6 `id.uuidString` unlock path). Re-key them to lowercase,
        // merging into an existing lowercase twin (unioning `sources`) so a
        // stale uppercase record can never again dodge `removeSource`.
        let sweptShields = ScreenTimeRecordKeySweep.sweep(shieldRecords)
        if Set(sweptShields.keys) != Set(shieldRecords.keys) {
            migrated = true
        }
        shieldRecords = sweptShields

        let expired = purgeExpiredRecords()
        if migrated || !expired.shields.isEmpty || !expired.blocks.isEmpty {
            persist()
        }
        recomputeAndApply()
    }

    private func normalizeShieldRecord(_ record: ShieldRecord) -> (record: ShieldRecord, migrated: Bool) {
        record.normalizedForCurrentSchema()
    }

    @discardableResult
    private func purgeExpiredRecords(now: Date = Date()) -> (shields: [ShieldRecord], blocks: [BlockRecord]) {
        let expiredShields = shieldRecords.values.filter { ($0.expiresAt ?? .distantFuture) <= now }
        for record in expiredShields {
            shieldRecords.removeValue(forKey: record.recordKey)
        }

        let expiredBlocks = blockRecords.values.filter { ($0.expiresAt ?? .distantFuture) <= now }
        for record in expiredBlocks {
            blockRecords.removeValue(forKey: record.bundleID)
        }

        return (expiredShields, expiredBlocks)
    }
}

/// Shared by the notification-service wire mapper and its executable app tests.
/// Top-level command provenance has the same precedence as `CommandPoller`.
nonisolated enum NSECommandSourceResolver {
    static func lockSource(topLevel: String?, target: String?) -> String? {
        topLevel ?? target
    }

    static func unlockSources(topLevel: [String]?, target: [String]?) -> [String]? {
        topLevel ?? target
    }

    static func shieldSources(from wireValue: String?) -> Set<ShieldSource> {
        switch wireValue {
        case "earned_time": return [.earnedTime]
        case "task_pause": return [.taskPause]
        default: return [.manual]
        }
    }

    static func shieldSource(from wireValue: String) -> ShieldSource {
        shieldSources(from: wireValue).first ?? .manual
    }
}

/// Testable final construction shared with the notification-service extension.
/// Keeping provenance here prevents the NSE from silently taking ShieldRecord's
/// legacy `.manual` default when a command carries an automatic source.
enum NSEShieldRecordFactory {
    static func make(
        command: LockCommand,
        tier: ShieldTier,
        targetKey: String,
        displayName: String,
        appTokens: Set<ApplicationToken>,
        categoryTokens: Set<ActivityCategoryToken>,
        webDomainTokens: Set<WebDomainToken>,
        appliesToAll: Bool,
        expiresAt: Date?
    ) -> ShieldRecord {
        ShieldRecord(
            recordKey: ShieldRecord.makeRecordKey(tier: tier, targetKey: targetKey),
            tier: tier,
            targetKey: targetKey,
            displayName: displayName,
            lastCommandID: command.id,
            appTokens: appTokens,
            categoryTokens: categoryTokens,
            webDomainTokens: webDomainTokens,
            appliesToAll: appliesToAll,
            issuedAt: command.issuedAt,
            expiresAt: expiresAt,
            originalRequest: command.target.originalRequest,
            targetChildID: command.target.targetChildID ?? UUID(),
            sources: NSECommandSourceResolver.shieldSources(from: command.lockSource)
        )
    }
}

/// Runs before the NSE's action switch. It owns all shield-removal dispatch so
/// override metadata cannot bypass validation through another destructive action.
enum NSELockMutationDispatcher {
    enum Outcome: Equatable {
        case notHandled
        case rejected
        case unshield
        case unshieldAll
    }

    static func apply(
        _ command: LockCommand,
        recordKey: String,
        store: ActiveLockStore = .shared,
        earnedTimeStore: EarnedTimeStore = .shared,
        fetchedDeviceID: UUID? = nil,
        currentDeviceID: UUID? = nil,
        currentUsageDate: String? = nil,
        beforeSourceMutation: @escaping () -> Void = {}
    ) async -> Outcome {
        var overrideMarkerApplied = false
        if command.target.earnedOverrideUsageDate != nil {
            guard command.action == .unshield,
                  let fetchedDeviceID,
                  currentDeviceID == fetchedDeviceID,
                  command.target.targetChildID == fetchedDeviceID,
                  case .applied = EarnedOverrideCommandApplier.applyIfPresent(
                      command,
                      currentUsageDate: currentUsageDate,
                      store: earnedTimeStore
                  )
            else { return .rejected }
            overrideMarkerApplied = true
        }

        switch command.action {
        case .unshield:
            guard await NSEUnshieldCommandApplier.apply(
                command,
                recordKey: recordKey,
                store: store,
                earnedTimeStore: earnedTimeStore,
                fetchedDeviceID: fetchedDeviceID,
                currentDeviceID: currentDeviceID,
                currentUsageDate: currentUsageDate,
                overrideMarkerApplied: overrideMarkerApplied,
                beforeSourceMutation: beforeSourceMutation
            ) == .confirmed else { return .rejected }
            return .unshield
        case .unshieldAll:
            _ = await store.unshieldAll()
            return .unshieldAll
        default:
            return .notHandled
        }
    }
}

/// Source-aware unshield mutation used by the NSE. A non-nil source list is a
/// scoped command; legacy commands without provenance retain whole-record semantics.
enum NSEUnshieldCommandApplier {
    enum Outcome: Equatable {
        case confirmed
    }

    static func apply(
        _ command: LockCommand,
        recordKey: String,
        store: ActiveLockStore = .shared,
        earnedTimeStore: EarnedTimeStore = .shared,
        fetchedDeviceID: UUID? = nil,
        currentDeviceID: UUID? = nil,
        currentUsageDate: String? = nil,
        overrideMarkerApplied: Bool = false,
        beforeSourceMutation: @escaping () -> Void = {}
    ) async -> Outcome? {
        guard command.action == .unshield else { return nil }

        if !overrideMarkerApplied {
            if command.target.earnedOverrideUsageDate != nil {
                guard let fetchedDeviceID,
                      currentDeviceID == fetchedDeviceID,
                      command.target.targetChildID == fetchedDeviceID
                else { return nil }
            }

            switch EarnedOverrideCommandApplier.applyIfPresent(
                command,
                currentUsageDate: currentUsageDate,
                store: earnedTimeStore
            ) {
            case .invalid:
                return nil
            case .applied where command.target.listID == nil:
                return .confirmed
            case .absent, .applied:
                break
            }
        } else if command.target.listID == nil {
            return .confirmed
        }

        if let wireSources = command.unlockSources {
            for wireSource in wireSources {
                beforeSourceMutation()
                await store.removeSource(
                    NSECommandSourceResolver.shieldSource(from: wireSource),
                    fromRecordKey: recordKey
                )
            }
        } else {
            _ = await store.removeShield(recordKey: recordKey)
        }
        return .confirmed
    }
}
