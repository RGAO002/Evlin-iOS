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
        guard let record = shieldRecords.removeValue(forKey: recordKey) else { return nil }
        persist()
        recomputeAndApply()
        let stillCovered = findRemainingCoverage(of: record)
        let blocked = false
        return RemovedShield(record: record, stillCovered: stillCovered, blockedAfter: blocked)
    }

    @discardableResult
    func unshieldAll() -> [ShieldRecord] {
        let removed = Array(shieldRecords.values)
        shieldRecords.removeAll()
        persist()
        recomputeAndApply()
        return removed
    }

    // MARK: - Block API

    @discardableResult
    func addBlock(_ new: BlockRecord) -> AddBlockResult {
        if blockRecords[new.bundleID] != nil { return .alreadyBlocked }
        blockRecords[new.bundleID] = new
        persist()
        recomputeAndApply()
        return .added
    }

    @discardableResult
    func removeBlock(bundleID: String, categoryHint: String? = nil) -> RemovedBlock? {
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
        let expired = shieldRecords.values.filter { ($0.expiresAt ?? .distantFuture) <= now }
        guard !expired.isEmpty else { return [] }
        for record in expired { shieldRecords.removeValue(forKey: record.recordKey) }
        persist()
        recomputeAndApply()
        return expired
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
        case .all:
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
                return !other.appTokens.isDisjoint(with: removed.appTokens) || other.tier == .all
            case .savedList:
                return !other.appTokens.isDisjoint(with: removed.appTokens) ||
                       !other.categoryTokens.isDisjoint(with: removed.categoryTokens) ||
                       other.tier == .all
            case .category:
                return (other.tier == .category && other.targetKey == removed.targetKey) ||
                       other.tier == .all
            case .all:
                return false
            }
        }
    }

    // MARK: - Private: recompute + persistence

    private func recomputeAndApply() {
        // Blocks
        let blockedApps = Set(blockRecords.values.map { ManagedSettings.Application(bundleIdentifier: $0.bundleID) })
        store.application.blockedApplications = blockedApps.isEmpty ? nil : blockedApps

        // Check for 'all' tier — if any, shield everything
        if shieldRecords.values.contains(where: { $0.appliesToAll }) {
            store.shield.applicationCategories = .all()
            store.shield.webDomainCategories = .all()
            store.shield.applications = nil
            store.shield.webDomains = nil
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
    }

    private func persist() {
        // `PropertyListEncoder` can trip `swift_dynamicCastFailure` encoding
        // `ShieldRecord`'s FamilyControls token sets (crash seen iOS 26 / TestFlight).
        // JSON survives the full Codable surface for `[String: ShieldRecord]`.
        if let data = try? JSONEncoder().encode(shieldRecords) {
            defaults?.set(data, forKey: shieldsKey)
        }
        if let data = try? JSONEncoder().encode(blockRecords) {
            defaults?.set(data, forKey: blocksKey)
        }
    }

    private func restore() {
        if let data = defaults?.data(forKey: shieldsKey) {
            if let decoded = try? JSONDecoder().decode([String: ShieldRecord].self, from: data) {
                shieldRecords = decoded
            } else if let decoded = try? PropertyListDecoder().decode([String: ShieldRecord].self, from: data) {
                shieldRecords = decoded
                // One-shot migrate legacy plist payloads to JSON.
                persist()
            }
        }
        if let data = defaults?.data(forKey: blocksKey) {
            if let decoded = try? JSONDecoder().decode([String: BlockRecord].self, from: data) {
                blockRecords = decoded
            } else if let decoded = try? PropertyListDecoder().decode([String: BlockRecord].self, from: data) {
                blockRecords = decoded
                persist()
            }
        }
    }
}
