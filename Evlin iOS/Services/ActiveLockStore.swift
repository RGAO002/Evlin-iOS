import Foundation
import FamilyControls
import ManagedSettings

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

    private var shieldRecords: [String: ShieldRecord] = [:]
    private var blockRecords: [String: BlockRecord] = [:]
    private let store = ManagedSettingsStore()
    private let defaults = UserDefaults(suiteName: "group.com.evlin.ios")
    private let shieldsKey = "evlin.shieldRecords"
    private let blocksKey = "evlin.blockRecords"

    init() {
        restore()
    }

    // MARK: - Shield API

    /// Add a shield. If `force == true`, the merge rule is skipped — use this
    /// ONLY when the parent has confirmed a downgrade via the B1 card. The caller
    /// (ActionExecutor) reads the `force_downgrade` flag from the Command payload;
    /// the parent UI sends that flag by re-submitting the Chat message with
    /// `force_confirmations: ["B1"]` in the request.
    @discardableResult
    func addShield(_ new: ShieldRecord, force: Bool = false) -> AddShieldResult {
        reconcileLimitShieldsFromDisk()
        let new = normalizeShieldRecord(new).record
        if let existing = shieldRecords[new.recordKey], !force {
            return mergeShield(existing: existing, new: new)
        }
        // force=true OR no existing record → overwrite
        shieldRecords[new.recordKey] = new
        persist()
        recomputeAndApply()
        return .added
    }

    @discardableResult
    func removeShield(recordKey: String) -> RemovedShield? {
        reconcileLimitShieldsFromDisk()
        guard let record = shieldRecords.removeValue(forKey: recordKey) else { return nil }
        persist()
        recomputeAndApply()
        let stillCovered = findRemainingCoverage(of: record)
        let blocked = false
        return RemovedShield(record: record, stillCovered: stillCovered, blockedAfter: blocked)
    }

    @discardableResult
    func unshieldAll() -> [ShieldRecord] {
        reconcileLimitShieldsFromDisk()
        let removed = Array(shieldRecords.values)
        shieldRecords.removeAll()
        persist()
        recomputeAndApply()
        return removed
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
        reconcileLimitShieldsFromDisk()
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
        // Reconcile FIRST so we target the extension's CURRENT `.limit` set (a
        // threshold may have fired since init). Then compute + remove targets,
        // then persist (writes disk WITHOUT the targets), then recompute. Because
        // persist writes the removal to disk before recompute's reconcile re-reads
        // it, the removed records are NOT resurrected.
        reconcileLimitShieldsFromDisk()
        let bidKey = bundleID?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let toRemove = shieldRecords.values.filter { record in
            guard record.source == .limit else { return false }
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
    }

    // MARK: - Block API

    @discardableResult
    func addBlock(_ new: BlockRecord) -> AddBlockResult {
        reconcileLimitShieldsFromDisk()
        if blockRecords[new.bundleID] != nil { return .alreadyBlocked }
        blockRecords[new.bundleID] = new
        persist()
        recomputeAndApply()
        return .added
    }

    @discardableResult
    func removeBlock(bundleID: String, categoryHint: String? = nil) -> RemovedBlock? {
        reconcileLimitShieldsFromDisk()
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
    }

    @discardableResult
    func unblockAll() -> [BlockRecord] {
        reconcileLimitShieldsFromDisk()
        let removed = Array(blockRecords.values)
        blockRecords.removeAll()
        persist()
        recomputeAndApply()
        return removed
    }

    // MARK: - Queries

    func allCurrent() -> (shields: [ShieldRecord], blocks: [BlockRecord]) {
        (Array(shieldRecords.values), Array(blockRecords.values))
    }

    func reapplyCurrentRestrictions() {
        reconcileLimitShieldsFromDisk()
        recomputeAndApply()
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
        reconcileLimitShieldsFromDisk()
        let expired = purgeExpiredRecords(now: now)
        guard !expired.shields.isEmpty || !expired.blocks.isEmpty else { return [] }
        persist()
        recomputeAndApply()
        return expired.shields
    }

    // MARK: - Private: merge

    private func mergeShield(existing: ShieldRecord, new: ShieldRecord) -> AddShieldResult {
        let existingPermanent = existing.expiresAt == nil
        let newPermanent = new.expiresAt == nil

        if existingPermanent && newPermanent {
            return .noOpAlreadyPermanent
        }
        if existingPermanent && !newPermanent {
            return .needsConfirmation(.downgradePermanentToTimed(
                existingKey: existing.recordKey,
                newExpiry: new.expiresAt!
            ))
        }
        if !existingPermanent && newPermanent {
            var upgraded = existing
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
            var extended = existing
            extended.expiresAt = new.expiresAt
            extended.lastCommandID = new.lastCommandID
            shieldRecords[existing.recordKey] = extended
            persist()
            recomputeAndApply()
            return .extendedTimed(newExpiry: new.expiresAt!)
        }
        return .noOpShorterThanExisting
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
        // Covers the read-only reapply path and guarantees the union we push to
        // the ManagedSettingsStore includes the extension's current `.limit`
        // records. Safe for `removeLimitShields`: that path persists the removal
        // to disk BEFORE calling here, so this reconcile re-reads disk without
        // the removed records and cannot resurrect them.
        reconcileLimitShieldsFromDisk()
        let expired = purgeExpiredRecords()
        if !expired.shields.isEmpty || !expired.blocks.isEmpty {
            persist()
        }

        // Blocks
        let blockedApps = Set(blockRecords.values.map { ManagedSettings.Application(bundleIdentifier: $0.bundleID) })
        store.application.blockedApplications = blockedApps.isEmpty ? nil : blockedApps

        // Check for broad app shields. Parent all-locks still block all web
        // domains; reflection all-app locks leave web domains available so
        // embedded YouTube reflection videos can load.
        let broadRecords = shieldRecords.values.filter(\.appliesToAll)
        if !broadRecords.isEmpty {
            let includesFullWebShield = broadRecords.contains(where: { $0.tier == .all })
            let allWebTokens = Set(shieldRecords.values.flatMap(\.webDomainTokens))
            store.shield.applicationCategories = .all()
            store.shield.applications = nil
            if includesFullWebShield {
                store.shield.webDomainCategories = .all()
                store.shield.webDomains = nil
                writeRecomputeDiag(branch: "all", appTokens: 0, catTokens: 0, webTokens: 0)
            } else {
                store.shield.webDomainCategories = nil
                store.shield.webDomains = allWebTokens.isEmpty ? nil : allWebTokens
                writeRecomputeDiag(branch: "all_apps_only", appTokens: 0, catTokens: 0, webTokens: allWebTokens.count)
            }
            return
        }

        // Otherwise union tokens
        let allAppTokens = Set(shieldRecords.values.flatMap(\.appTokens))
        let allCatTokens = Set(shieldRecords.values.flatMap(\.categoryTokens))
        let allWebTokens = Set(shieldRecords.values.flatMap(\.webDomainTokens))

        store.shield.applications = allAppTokens.isEmpty ? nil : allAppTokens
        store.shield.applicationCategories = allCatTokens.isEmpty ? nil : .specific(allCatTokens)
        store.shield.webDomains = allWebTokens.isEmpty ? nil : allWebTokens
        store.shield.webDomainCategories = nil
        writeRecomputeDiag(
            branch: "union",
            appTokens: allAppTokens.count,
            catTokens: allCatTokens.count,
            webTokens: allWebTokens.count
        )
    }

    /// Records the most recent recomputeAndApply() invocation to the App Group
    /// so HomeSettingsSheet can surface it. This is the only way to verify
    /// that sweepExpired → recomputeAndApply actually executed AND what value
    /// it wrote to `store.shield.applications` (which we can't read back).
    private func writeRecomputeDiag(branch: String, appTokens: Int, catTokens: Int, webTokens: Int) {
        let ts = ISO8601DateFormatter().string(from: Date())
        let line = "\(ts) branch=\(branch) shields=\(shieldRecords.count) blocks=\(blockRecords.count)"
            + " apps=\(appTokens) cats=\(catTokens) webs=\(webTokens)"
        defaults?.set(line, forKey: "evlin.lastRecompute")
    }

    // MARK: - Private: cross-process limit-shield reconciliation

    /// Read + decode the App Group `shieldsKey` dict using the SAME `.iso8601`
    /// decoder (with the legacy `PropertyListDecoder` fallback) that `restore()`
    /// uses. Returns `nil` on missing data OR decode failure — the caller MUST
    /// distinguish "couldn't read" (do nothing) from "read an empty dict"
    /// (`[:]`, which legitimately means the extension cleared every limit shield).
    private func diskShieldRecords() -> [String: ShieldRecord]? {
        guard let data = defaults?.data(forKey: shieldsKey) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let decoded = try? decoder.decode([String: ShieldRecord].self, from: data) {
            return decoded
        }
        if let decoded = try? PropertyListDecoder().decode([String: ShieldRecord].self, from: data) {
            return decoded
        }
        return nil
    }

    /// Reconcile the in-memory `source == .limit` subset with the on-disk
    /// `source == .limit` subset. `.limit` records are OWNED by the
    /// DeviceActivity extension (it writes them on a usage-threshold fire and
    /// removes them at the daily reset, directly into the same App Group dict).
    /// The main app never re-reads that dict after init, so without this its
    /// stale in-memory copy would erase the extension's writes on the next
    /// `persist()`/`recomputeAndApply()`. Call this at the START of every
    /// mutating method, BEFORE it mutates/persists.
    ///
    /// `source == .manual` records remain main-app-authoritative and are NEVER
    /// touched here.
    ///
    /// Fail-safe: if disk can't be read/decoded (`diskShieldRecords() == nil`),
    /// this is a NO-OP — a transient read failure must never wipe in-memory
    /// shields.
    private func reconcileLimitShieldsFromDisk() {
        guard let disk = diskShieldRecords() else { return }

        let diskLimit = disk.filter { $0.value.source == .limit }

        // (a) Drop any in-memory `.limit` record that is no longer a `.limit`
        // record on disk (picks up the extension's daily-reset clears).
        for (key, record) in shieldRecords where record.source == .limit {
            if diskLimit[key] == nil {
                shieldRecords.removeValue(forKey: key)
            }
        }

        // (b) Insert/update every disk `.limit` record (picks up the
        // extension's threshold writes). Normalize for schema parity, exactly
        // like `restore()` does.
        for (key, record) in diskLimit {
            shieldRecords[key] = normalizeShieldRecord(record).record
        }
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
